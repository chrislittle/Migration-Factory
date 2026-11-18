# Edv4 size series - Azure Virtual Machines | Microsoft Learn

Edv4-series sizes run on the Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8370C (Ice Lake) or the Intel® Xeon® Platinum 8272CL (Cascade Lake) processors. The Edv4 virtual machine sizes feature up to 504 GiB of RAM, in addition to fast and large local SSD storage (up to 2,400 GiB). These virtual machines are ideal for memory-intensive enterprise applications and applications that benefit from low latency, high-speed local storage. You can attach Standard SSDs and Standard HDDs disk storage to the Edv4 VMs.

## Host specifications

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 64 vCPUs | Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8272CL (Cascade Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 16 - 504 GiB |  |
| Local Storage | 1 Disk | 75 - 2400 GiB 9000 - 300000 IOPS 125 - 4000 MBps |
| Remote Storage | 4 - Disks | 3200 - IOPS 48 - MBps |
| Network | 2 - 8 NICs | 5000 - 30000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

For features supported by this series, see the Feature support section.

## Sizes in series

# [Basics](#tab/sizebasic)
vCPUs (Qty.) and Memory for each size

| Size Name | vCPUs (Qty.) | Memory (GB) |
| --- | --- | --- |
| Standard\_E2d\_v4 | 2 | 16 |
| Standard\_E4d\_v4 | 4 | 32 |
| Standard\_E8d\_v4 | 8 | 64 |
| Standard\_E16d\_v4 | 16 | 128 |
| Standard\_E20d\_v4 | 20 | 160 |
| Standard\_E32d\_v4 | 32 | 256 |
| Standard\_E48d\_v4 | 48 | 384 |
| Standard\_E64d\_v4 | 64 | 504 |

#### VM Basics resources

- [Check vCPU quotas](../../quotas)

# [Local storage](#tab/sizestoragelocal)
Local (temp) storage info for each size

| Size Name | Max Temp Storage Disks (Qty.) | Temp Disk Size (GiB) | Temp Disk Random Read (RR)^1^IOPS | Temp Disk Random Read (RR)^1^Throughput (MB/s) |
| --- | --- | --- | --- | --- |
| Standard\_E2d\_v4 | 1 | 75 | 9000 | 125 |
| Standard\_E4d\_v4 | 1 | 150 | 19000 | 250 |
| Standard\_E8d\_v4 | 1 | 300 | 38000 | 500 |
| Standard\_E16d\_v4 | 1 | 600 | 75000 | 1000 |
| Standard\_E20d\_v4 | 1 | 750 | 94000 | 1250 |
| Standard\_E32d\_v4 | 1 | 1200 | 150000 | 2000 |
| Standard\_E48d\_v4 | 1 | 1800 | 225000 | 3000 |
| Standard\_E64d\_v4 | 1 | 2400 | 300000 | 4000 |

#### Storage resources

- [Introduction to Azure managed disks](../../managed-disks-overview)
- [Azure managed disk types](../../disks-types)
- [Share an Azure managed disk](../../disks-shared)

#### Table definitions

- ^1^Temp disk speed often differs between RR (Random Read) and RW (Random Write) operations. RR operations are typically faster than RW operations. The RW speed is usually slower than the RR speed on series where only the RR speed value is listed.
- Storage capacity is shown in units of GiB or 1024^3 bytes. When you compare disks measured in GB (1000^3 bytes) to disks measured in GiB (1024^3) remember that capacity numbers given in GiB may appear smaller. For example, 1023 GiB = 1098.4 GB.
- Disk throughput is measured in input/output operations per second (IOPS) and MBps where MBps = 10^6 bytes/sec.
- To learn how to get the best storage performance for your VMs, see [Virtual machine and disk performance](../../disks-performance).

# [Remote storage](#tab/sizestorageremote)
Remote (uncached) storage info for each size

| Size Name | Max Remote Storage Disks (Qty.) | Uncached Premium SSD IOPS | Uncached Premium SSD Throughput (MB/s) | Uncached Premium SSD Burst^1^IOPS | Uncached Premium SSD Burst^1^Throughput (MB/s) |
| --- | --- | --- | --- | --- | --- |
| Standard\_E2d\_v4 | 4 | 3200 | 48 | 4000 | 200 |
| Standard\_E4d\_v4 | 8 | 6400 | 96 | 8000 | 200 |
| Standard\_E8d\_v4 | 16 | 12800 | 192 | 16000 | 400 |
| Standard\_E16d\_v4 | 32 | 25600 | 384 | 32000 | 800 |
| Standard\_E20d\_v4 | 32 | 32000 | 480 | 40000 | 1000 |
| Standard\_E32d\_v4 | 32 | 51200 | 768 | 64000 | 1600 |
| Standard\_E48d\_v4 | 32 | 76800 | 1152 | 80000 | 2000 |
| Standard\_E64d\_v4 | 32 | 80000 | 1200 | 80000 | 2000 |

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
| Standard\_E2d\_v4 | 2 | 5000 |
| Standard\_E4d\_v4 | 2 | 10000 |
| Standard\_E8d\_v4 | 4 | 12500 |
| Standard\_E16d\_v4 | 8 | 12500 |
| Standard\_E20d\_v4 | 8 | 16000 |
| Standard\_E32d\_v4 | 8 | 16000 |
| Standard\_E48d\_v4 | 8 | 24000 |
| Standard\_E64d\_v4 | 8 | 30000 |

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
| [Generation 2 VMs](../../generation-2) | Supported |
| [Generation 1 VMs](../../generation-2) | Supported |
| [Accelerated Networking](/en-us/azure/virtual-network/create-vm-accelerated-networking-cli) | Supported |
| [Ephemeral OS Disk](../../ephemeral-os-disks) | Not Supported |
| [Local temporary storage](../../overview#local-temporary-storage) | Supported |
| [Nested Virtualization](/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization) | Supported |

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
