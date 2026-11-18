# Esv5 size series - Azure Virtual Machines | Microsoft Learn

Esv5-series virtual machines run on Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8473C (Sapphire Rapids) or Intel® Xeon® Platinum 8370C (Ice Lake) processor in a [hyper threaded](https://www.intel.com/content/www/us/en/gaming/resources/hyper-threading.html) configuration. This new processor features an all core turbo clock speed of 3.5 GHz with [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html) and [Intel® Deep Learning Boost](https://software.intel.com/content/www/us/en/develop/topics/ai/deep-learning-boost.html). These virtual machines offer up to 104 vCPU and 672 GiB of RAM. Esv5-series virtual machines don't have temporary storage thus lowering the price of entry.

Esv5-series supports Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

## Host specifications

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 104 vCPUs | Intel Xeon Platinum 8473C (Sapphire Rapids) [x86-64] Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 16 - 672 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 64 Disks | 3750 - 120000 IOPS 85 - 4000 MBps |
| Network | 2 - 8 NICs | 12500 - 100000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

For features supported by this series, see the Feature support section.

## Sizes in series

# [Basics](#tab/sizebasic)
vCPUs (Qty.) and Memory for each size

| Size Name | vCPUs (Qty.) | Memory (GB) |
| --- | --- | --- |
| Standard\_E2s\_v5 | 2 | 16 |
| Standard\_E4s\_v5 | 4 | 32 |
| Standard\_E8s\_v5 | 8 | 64 |
| Standard\_E16s\_v5 | 16 | 128 |
| Standard\_E20s\_v5 | 20 | 160 |
| Standard\_E32s\_v5 | 32 | 256 |
| Standard\_E48s\_v5 | 48 | 384 |
| Standard\_E64s\_v5 | 64 | 512 |
| Standard\_E96s\_v5 | 96 | 672 |
| Standard\_E104is\_v5 | 104 | 672 |

#### VM Basics resources

- [Check vCPU quotas](../../quotas)

# [Local storage](#tab/sizestoragelocal)
Local (temp) storage info for each size

Note

No local storage present in this series.

For frequently asked questions, see [Azure VM sizes with no local temp disk](../../azure-vms-no-temp-disk).

# [Remote storage](#tab/sizestorageremote)
Remote (uncached) storage info for each size

| Size Name | Max Remote Storage Disks (Qty.) | Uncached Premium SSD IOPS | Uncached Premium SSD Throughput (MB/s) | Uncached Premium SSD Burst^1^IOPS | Uncached Premium SSD Burst^1^Throughput (MB/s) |
| --- | --- | --- | --- | --- | --- |
| Standard\_E2s\_v5 | 4 | 3750 | 85 | 10000 | 1200 |
| Standard\_E4s\_v5 | 8 | 6400 | 145 | 20000 | 1200 |
| Standard\_E8s\_v5 | 16 | 12800 | 290 | 20000 | 1200 |
| Standard\_E16s\_v5 | 32 | 25600 | 600 | 40000 | 1200 |
| Standard\_E20s\_v5 | 32 | 32000 | 750 | 64000 | 1600 |
| Standard\_E32s\_v5 | 32 | 51200 | 865 | 80000 | 2000 |
| Standard\_E48s\_v5 | 32 | 76800 | 1315 | 80000 | 3000 |
| Standard\_E64s\_v5 | 32 | 80000 | 1735 | 80000 | 3000 |
| Standard\_E96s\_v5 | 32 | 80000 | 2600 | 80000 | 4000 |
| Standard\_E104is\_v5 | 64 | 120000 | 4000 | 120000 | 4000 |

#### Storage resources

- [Introduction to Azure managed disks](../../managed-disks-overview)
- [Azure managed disk types](../../disks-types)
- [Share an Azure managed disk](../../disks-shared)

#### Table definitions

- ^1^Some sizes support [bursting](../../disk-bursting) to temporarily increase disk performance. Burst speeds can be maintained for up to 30 minutes at a time.
- Storage capacity is shown in units of GiB or 1024^3 bytes. When you compare disks measured in GB (1000^3 bytes) to disks measured in GiB (1024^3) remember that capacity numbers given in GiB may appear smaller. For example, 1023 GiB = 1098.4 GB.
- Disk throughput is measured in input/output operations per second (IOPS) and MBps where MBps = 10^6 bytes/sec.
- Data disks can operate in cached or uncached modes. For cached data disk operation, the host cache mode is set to ReadOnly or ReadWrite. For uncached data disk operation, the host cache mode is set to None.
- To learn how to get the best storage performance for your VMs, see [Virtual machine and disk performance](../../disks-performance).

# [Network](#tab/sizenetwork)
Network interface info for each size

| Size Name | Max NICs (Qty.) | Max Network Bandwidth (Mb/s) |
| --- | --- | --- |
| Standard\_E2s\_v5 | 2 | 12500 |
| Standard\_E4s\_v5 | 2 | 12500 |
| Standard\_E8s\_v5 | 4 | 12500 |
| Standard\_E16s\_v5 | 8 | 12500 |
| Standard\_E20s\_v5 | 8 | 12500 |
| Standard\_E32s\_v5 | 8 | 16000 |
| Standard\_E48s\_v5 | 8 | 24000 |
| Standard\_E64s\_v5 | 8 | 30000 |
| Standard\_E96s\_v5 | 8 | 35000 |
| Standard\_E104is\_v5 | 8 | 100000 |

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
| [Accelerated Networking](/en-us/azure/virtual-network/create-vm-accelerated-networking-cli) | Required |
| [Ephemeral OS Disk](../../ephemeral-os-disks) | Not Supported |
| [Nested Virtualization](/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization) | Supported |

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
