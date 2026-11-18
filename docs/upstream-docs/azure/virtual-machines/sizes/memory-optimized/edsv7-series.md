# Edsv7 size series - Azure Virtual Machines | Microsoft Learn

Edsv7-series virtual machines run on the Intel® Xeon® 6 6973PC (Granite Rapids) processor reaching an all-core turbo clock speed of 3.6 GHz with a maximum turbo frequency of 4.2 GHz. This new processor features [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html), and [Intel® Advanced Matrix Extensions](https://www.intel.com/content/www/us/en/products/docs/accelerator-engines/advanced-matrix-extensions/overview.html). These virtual machines offer up to 372 vCPUs and 2,832 GiB of RAM. Edsv7-series virtual machines provide better performance for most general-purpose workloads compared to the prior generation, for example increased networking, increased remote storage performance, upgraded CPU, elevated memory bandwidth, faster NVMe local storage access, increased scalability, and larger local storage capacity.

Edsv7-series virtual machines are ideal for memory-intensive workloads, such as SQL and NoSQL database servers, data analytics engines, data warehousing workloads, business intelligence applications, in-memory databases such as SAP and Redis, and in-memory analytics and more.

## Host specifications

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 372 vCPUs | Intel@ Xeon® 6 6973P-C (Granite Rapids) [x86-64] |
| Memory | 16 - 2,832 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 3,520 GiB  50,000 - 9,600,000 IOPS 280 - 53,760 MBps |
| Remote Storage [Premium SSD](../../disks-types#premium-ssds) | 10 - 64 Disks | 4,000 - 500,000 IOPS 115 - 16,000 MBps |
| Remote Storage [Premium SSD v2](../../disks-types#premium-ssd-v2) / [Ultra Disks](../../disks-types#ultra-disks) | 10 - 64 Disks | 5,000 - 800,000 IOPS 135 - 20,000 MBps |
| Network | 3 - 15 NICs | 16,000 - 400,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

For features supported by this series, see the Feature support section.

## Sizes in series

# [Basics](#tab/sizebasic)
vCPUs (Qty.) and Memory for each size

| Size Name | vCPUs (Qty.) | Memory (GiB) |
| --- | --- | --- |
| Standard\_E2ds\_v7 | 2 | 16 |
| Standard\_E4ds\_v7 | 4 | 32 |
| Standard\_E8ds\_v7 | 8 | 64 |
| Standard\_E16ds\_v7 | 16 | 128 |
| Standard\_E20ds\_v7 | 20 | 160 |
| Standard\_E32ds\_v7 | 32 | 256 |
| Standard\_E48ds\_v7 | 48 | 384 |
| Standard\_E64ds\_v7 | 64 | 512 |
| Standard\_E96ds\_v7 | 96 | 768 |
| Standard\_E128ds\_v7 | 128 | 1,024 |
| Standard\_E192ds\_v7 | 192 | 1,536 |
| Standard\_E248ds\_v7 | 248 | 1,888 |
| Standard\_E372ids\_v7 | 372 | 2,832 |

#### VM Basics resources

- [Check vCPU quotas](../../quotas)

# [Local storage](#tab/sizestoragelocal)
Local (temp) storage info for each size

| Size Name | Max Temp Storage Disks (Qty.) | Temp Disk Size (GiB) | Temp Disk Random Read^1^IOPS | Temp Disk Sequential Read^1^Throughput (MBps) | Temp Disk Random Write^1^IOPS | Temp Disk Sequential Write^1^Throughput (MBps) |
| --- | --- | --- | --- | --- | --- | --- |
| Standard\_E2ds\_v7 | 1 | 110 | 50,000 | 280 | 25,000 | 140 |
| Standard\_E4ds\_v7 | 1 | 220 | 100,000 | 560 | 50,000 | 280 |
| Standard\_E8ds\_v7 | 1 | 440 | 200,000 | 1,120 | 100,000 | 560 |
| Standard\_E16ds\_v7 | 2 | 440 | 400,000 | 2,240 | 200,000 | 1,120 |
| Standard\_E20ds\_v7 | 2 | 550 | 500,000 | 2,800 | 250,000 | 1,400 |
| Standard\_E32ds\_v7 | 4 | 440 | 800,000 | 4,480 | 400,000 | 2,240 |
| Standard\_E48ds\_v7 | 6 | 440 | 1,200,000 | 6,720 | 600,000 | 3,360 |
| Standard\_E64ds\_v7 | 4 | 880 | 1,600,000 | 8,960 | 800,000 | 4,480 |
| Standard\_E96ds\_v7 | 6 | 880 | 2,400,000 | 13,440 | 1,200,000 | 6,720 |
| Standard\_E128ds\_v7 | 4 | 1,760 | 3,200,000 | 17,920 | 1,600,000 | 8,960 |
| Standard\_E192ds\_v7 | 6 | 1,760 | 4,800,000 | 26,880 | 2,400,000 | 13,440 |
| Standard\_E248ds\_v7 | 5 | 2,816 | 6,400,000 | 35,840 | 3,200,000 | 17,000 |
| Standard\_E372ids\_v7 | 6 | 3,520 | 9,600,000 | 53,760 | 4,800,000 | 20,400 |

#### Storage resources

- [NVMe Overview](/en-us/azure/virtual-machines/nvme-overview)
- [FAQ for temp NVMe disks](/en-us/azure/virtual-machines/enable-nvme-temp-faqs)

#### Table definitions

- ^1^Total local temporary storage is calculated by multiplying the max number of storage disks with the temp disk size. For example, for the Standard\_D192ds\_v6, the total local temporary storage capacity is 6 x 1760 GiB = 10560 GiB.
- ^2^Temp disk performance depends on many factors including block size, workload patterns of read/writes, queue depth (QD), and others. Temp disk performance specifications should be viewed as best case performance numbers, assuming 4k block sizes and QD=256 for IOPS, and 256k block sizes with QD=64 for throughput. Read performance specs assume 100% reads, and write performance specs assume 100% writes. Additionally, write performance is heavily impacted by how many blocks in use on a device. Temp disk write performance specs assume a device has a clean slate to enable the best performance. During steady state operations, write performance is expected to be lower than the published specs.
- Storage capacity is shown in units of GiB or 1024^3 bytes. When you compare disks measured in GB (1000^3 bytes) to disks measured in GiB (1024^3) remember that capacity numbers given in GiB may appear smaller. For example, 1023 GiB = 1098.4 GB.
- Disk throughput is measured in input/output operations per second (IOPS) and MBps where MBps = 10^6 bytes/sec.
- To learn how to get the best storage performance for your VMs, see [Virtual machine and disk performance](../../disks-performance).
- NVMe temp disks are presented as raw NVMe devices that need to be initialized and formatted before use. For more details on how to format and initialize drives, refer to the [NVMe Temp Disk FAQ](/en-us/azure/virtual-machines/enable-nvme-temp-faqs)

# [Remote storage](#tab/sizestorageremote)
Remote (uncached) storage info for each size

| Size Name | Max Remote Storage Disks (Qty.) | Uncached Premium SSD IOPS | Uncached Premium SSD Throughput (MBps) | Uncached Premium SSD Burst^1^IOPS | Uncached Premium SSD Burst^1^Throughput (MBps) | Uncached Ultra Disk and Premium SSD v2 IOPS | Uncached Ultra Disk and Premium SSD v2 Throughput (MBps) | Uncached Burst^1^Ultra Disk and Premium SSD v2 IOPS | Uncached Burst^1^Ultra Disk and Premium SSD v2 Throughput (MBps) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Standard\_E2ds\_v7 | 10 | 4,000 | 115 | 45,000 | 1,410 | 5,000 | 135 | 56,250 | 1,640 |
| Standard\_E4ds\_v7 | 12 | 8,000 | 230 | 45,000 | 1,410 | 10,000 | 270 | 56,250 | 1,640 |
| Standard\_E8ds\_v7 | 26 | 16,000 | 460 | 45,000 | 1,410 | 20,000 | 540 | 56,250 | 1,640 |
| Standard\_E16ds\_v7 | 48 | 32,000 | 940 | 75,000 | 1,410 | 40,000 | 1,080 | 93,750 | 1,640 |
| Standard\_E20ds\_v7 | 48 | 40,000 | 1,150 | 75,000 | 1,410 | 50,000 | 1,350 | 93,750 | 1,640 |
| Standard\_E32ds\_v7 | 64 | 64,000 | 1,885 | 100,000 | 1,915 | 80,000 | 2,160 | 125,000 | 2,225 |
| Standard\_E48ds\_v7 | 64 | 96,000 | 2,830 | 160,000 | 2,875 | 120,000 | 3,285 | 200,000 | 3,335 |
| Standard\_E64ds\_v7 | 64 | 128,000 | 3,775 | 160,000 | 3,830 | 160,000 | 4,320 | 200,000 | 4,450 |
| Standard\_E96ds\_v7 | 64 | 192,000 | 5,665 | 200,000 | 5,745 | 240,000 | 6,570 | 205,000 | 6,675 |
| Standard\_E128ds\_v7 | 64 | 204,800 | 7,550 | 225,280 | 7,660 | 320,000 | 8,640 | 352,000 | 8,895 |
| Standard\_E192ds\_v7 | 64 | 307,200 | 11,325 | 350,000 | 12,000 | 480,000 | 13,140 | 546,875 | 13,930 |
| Standard\_E248ds\_v7 | 64 | 396,800 | 13,145 | 500,000 | 15,000 | 620,000 | 16,740 | 781,250 | 19,385 |
| Standard\_E372ids\_v7 | 64 | 500,000 | 16,000 | 500,000 | 16,000 | 800,000 | 20,000 | 800,000 | 20,000 |

#### Storage resources

- [Introduction to Azure managed disks](../../managed-disks-overview)
- [Azure managed disk types](../../disks-types)
- [Share an Azure managed disk](../../disks-shared)

#### Table definitions

- ^1^Some sizes support bursting to temporarily increase disk performance. Burst speeds can be maintained for up to 30 minutes at a time.
- Storage capacity is shown in units of GiB or 1024^3 bytes. When you compare disks measured in GB (1000^3 bytes) to disks measured in GiB (1024^3) remember that capacity numbers given in GiB may appear smaller. For example, 1023 GiB = 1098.4 GB.
- Disk throughput is measured in input/output operations per second (IOPS) and MBps where MBps = 10^6 bytes/sec.
- Data disks can operate in cached or uncached modes. For cached data disk operation, the host cache mode is set to ReadOnly or ReadWrite. For uncached data disk operation, the host cache mode is set to None.
- To learn how to get the best storage performance for your VMs, see [Virtual machine and disk performance](../../disks-performance).

# [Network](#tab/sizenetwork)
Network interface info for each size

| Size Name | Max NICs (Qty.) | Max Network Bandwidth (Mbps) |
| --- | --- | --- |
| Standard\_E2ds\_v7 | 3 | 16,000 |
| Standard\_E4ds\_v7 | 4 | 25,000 |
| Standard\_E8ds\_v7 | 4 | 25,000 |
| Standard\_E16ds\_v7 | 8 | 25,000 |
| Standard\_E20ds\_v7 | 8 | 25,000 |
| Standard\_E32ds\_v7 | 8 | 25,000 |
| Standard\_E48ds\_v7 | 8 | 35,000 |
| Standard\_E64ds\_v7 | 15 | 45,000 |
| Standard\_E96ds\_v7 | 15 | 70,000 |
| Standard\_E128ds\_v7 | 15 | 85,000 |
| Standard\_E192ds\_v7 | 15 | 100,000 |
| Standard\_E248ds\_v7 | 15 | 150,000 |
| Standard\_E372ids\_v7 | 15 | 400,000 |

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
| [Live Migration](../../maintenance-and-updates) | Supported |
| [Premium Storage caching](../../premium-storage-performance) | Supported |
| [Memory Preserving Updates](../../maintenance-and-updates) | Supported |
| [Generation 2 VMs](../../generation-2) | Supported |
| [Generation 1 VMs](../../generation-2) | Not Supported |
| [Accelerated Networking](/en-us/azure/virtual-network/create-vm-accelerated-networking-cli) | Supported |
| [Nested Virtualization](/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization) | Supported |

Note

This VM series will only work on OS images that support NVMe. If your current OS image doesn't have NVMe support, you’ll see an error message. [NVMe](../../enable-nvme-interface) support is available on the most popular OS images, and we're continuously improving OS image compatibility.

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
