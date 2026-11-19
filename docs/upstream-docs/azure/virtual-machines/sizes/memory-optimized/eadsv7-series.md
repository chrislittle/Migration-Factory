# Eadsv7 size series - Azure Virtual Machines | Microsoft Learn

Eadsv7-series VMs utilize AMD's 5th Generation EPYC™ 9005 processors that can achieve a boosted maximum frequency of up to 4.5 GHz. These virtual machines offer up to 160 vCPU and 1280 GiB of RAM. The Eadsv7-series sizes offer a combination of vCPU, memory, and fast local NVMe temporary storage that is ideal for memory-intensive enterprise applications. Eadsv7-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

## Host specifications

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 160 vCPUs | AMD EPYC 9005 (Turin) [x86-64] |
| Memory | 16 - 1280 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 2200 GiB 37500 - 3000000 IOPS 280 - 22400 MBps |
| Remote Storage [Premium SSD](../../disks-types#premium-ssds) | 10 - 64 Disks | 4000 - 212000 IOPS 118 - 10344 MBps |
| Remote Storage [Premium SSD v2](../../disks-types#premium-ssd-v2) / [Ultra Disks](../../disks-types#ultra-disks) | 10 - 64 Disks | 4400 - 310000 IOPS 136 - 10356 MBps |
| Network | 2 - 15 NICs | 16000 - 80000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

For features supported by this series, see the Feature support section.

## Sizes in series

# [Basics](#tab/sizebasic)
vCPUs (Qty.) and Memory for each size

| Size Name | vCPUs (Qty.) | Memory (GB) |
| --- | --- | --- |
| Standard\_E2ads\_v7 | 2 | 16 |
| Standard\_E4ads\_v7 | 4 | 32 |
| Standard\_E8ads\_v7 | 8 | 64 |
| Standard\_E16ads\_v7 | 16 | 128 |
| Standard\_E32ads\_v7 | 32 | 256 |
| Standard\_E48ads\_v7 | 48 | 384 |
| Standard\_E64ads\_v7 | 64 | 512 |
| Standard\_E96ads\_v7 | 96 | 768 |
| Standard\_E128ads\_v7 | 128 | 1024 |
| Standard\_E160ads\_v7 | 160 | 1280 |

#### VM Basics resources

- [Check vCPU quotas](../../quotas)

# [Local storage](#tab/sizestoragelocal)
Local (temp) storage info for each size

| Size Name | Max Temp Storage Disks (Qty.) | Temp Disk Size (GiB) | Temp Disk Random Read (RR)^1^IOPS | Temp Disk Random Read (RR)^1^Throughput (MB/s) | Temp Disk Random Write (RW)^1^IOPS | Temp Disk Random Write (RW)^1^Throughput (MB/s) |
| --- | --- | --- | --- | --- | --- | --- |
| Standard\_E2ads\_v7 | 1 | 110 | 37500 | 280 | 15000 | 140 |
| Standard\_E4ads\_v7 | 1 | 220 | 75000 | 560 | 30000 | 280 |
| Standard\_E8ads\_v7 | 1 | 440 | 150000 | 1120 | 60000 | 560 |
| Standard\_E16ads\_v7 | 2 | 440 | 300000 | 2240 | 120000 | 1120 |
| Standard\_E32ads\_v7 | 4 | 440 | 600000 | 4480 | 240000 | 2240 |
| Standard\_E48ads\_v7 | 6 | 440 | 900000 | 6720 | 360000 | 3360 |
| Standard\_E64ads\_v7 | 4 | 880 | 1200000 | 8960 | 480000 | 4480 |
| Standard\_E96ads\_v7 | 6 | 880 | 1800000 | 13440 | 720000 | 6720 |
| Standard\_E128ads\_v7 | 4 | 1760 | 2400000 | 17920 | 960000 | 8960 |
| Standard\_E160ads\_v7 | 4 | 2200 | 3000000 | 22400 | 1200000 | 11200 |

#### Storage resources

- [Introduction to Azure managed disks](../../managed-disks-overview)
- [Azure managed disk types](../../disks-types)
- [Share an Azure managed disk](../../disks-shared)

#### Table definitions

- ^1^ Temp disk speed often differs between RR (Random Read) and RW (Random Write) operations. RR operations are typically faster than RW operations. The RW speed is usually slower than the RR speed on series where only the RR speed value is listed. Temp disk performance can vary based on workload, block size, and system conditions. Published numbers show peak performance under controlled testing, temp disk performance specifications should be viewed as best case performance numbers and may differ in real-world scenarios. Factors such as data patterns, SSD wear, and background processes can affect write speeds. For more details, please see [FAQ for Temp NVMe disks](../../enable-nvme-temp-faqs)
- Storage capacity is shown in units of GiB or 1024^3 bytes. When you compare disks measured in GB (1000^3 bytes) to disks measured in GiB (1024^3) remember that capacity numbers given in GiB may appear smaller. For example, 1023 GiB = 1098.4 GB.
- Disk throughput is measured in input/output operations per second (IOPS) and MBps where MBps = 10^6 bytes/sec.
- To learn how to get the best storage performance for your VMs, see [Virtual machine and disk performance](../../disks-performance).

# [Remote storage](#tab/sizestorageremote)
Remote (uncached) storage info for each size

| Size Name | Max Remote Storage Disks (Qty.) | Uncached Premium SSD IOPS | Uncached Premium SSD Throughput (MB/s) | Uncached Premium SSD Burst^1^IOPS | Uncached Premium SSD Burst^1^Throughput (MB/s) | Uncached Ultra Disk and Premium SSD v2 IOPS | Uncached Ultra Disk and Premium SSD v2 Throughput (MB/s) | Uncached Burst^1^Ultra Disk and Premium SSD v2 IOPS | Uncached Burst^1^Ultra Disk and Premium SSD v2 Throughput (MB/s) |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Standard\_E2ads\_v7 | 10 | 4000 | 118 | 44000 | 1412 | 4400 | 136 | 48400 | 1653 |
| Standard\_E4ads\_v7 | 12 | 8000 | 234 | 47200 | 1412 | 8800 | 273 | 52083 | 1653 |
| Standard\_E8ads\_v7 | 26 | 16000 | 468 | 47200 | 1412 | 17600 | 547 | 52083 | 1653 |
| Standard\_E16ads\_v7 | 48 | 32000 | 936 | 72700 | 1412 | 35200 | 1095 | 80000 | 1653 |
| Standard\_E32ads\_v7 | 64 | 64000 | 1872 | 94400 | 1916 | 70400 | 2191 | 104167 | 2241 |
| Standard\_E48ads\_v7 | 64 | 96000 | 2808 | 99000 | 2874 | 105600 | 3291 | 108900 | 3362 |
| Standard\_E64ads\_v7 | 64 | 128000 | 3744 | 132000 | 3832 | 140800 | 4382 | 145200 | 4484 |
| Standard\_E96ads\_v7 | 64 | 192000 | 5663 | 192500 | 5749 | 211200 | 6573 | 211750 | 6669 |
| Standard\_E128ads\_v7 | 64 | 204800 | 7488 | 225280 | 7663 | 281600 | 8764 | 310886 | 8966 |
| Standard\_E160ads\_v7 | 64 | 212000 | 10344 | 242640 | 11410 | 310000 | 10356 | 355443 | 11450 |

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
| Standard\_E2ads\_v7 | 2 | 16000 |
| Standard\_E4ads\_v7 | 2 | 16000 |
| Standard\_E8ads\_v7 | 4 | 25000 |
| Standard\_E16ads\_v7 | 8 | 25000 |
| Standard\_E32ads\_v7 | 8 | 25000 |
| Standard\_E48ads\_v7 | 8 | 35000 |
| Standard\_E64ads\_v7 | 8 | 45000 |
| Standard\_E96ads\_v7 | 8 | 70000 |
| Standard\_E128ads\_v7 | 15 | 75000 |
| Standard\_E160ads\_v7 | 15 | 80000 |

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
| [Memory Preserving Updates](../../maintenance-and-updates#live-migration) | Supported |
| [Generation 2 VMs](../../generation-2) | Supported |
| [Generation 1 VMs](../../generation-2) | Not Supported |
| [Accelerated Networking](/en-us/azure/virtual-network/create-vm-accelerated-networking-cli) | Supported |
| [Ephemeral OS Disk](../../ephemeral-os-disks) | Supported |
| [Temporary local NVMe disks](../../enable-nvme-temp-faqs) | Supported |
| [Nested Virtualization](/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization) | Supported |

Note

This VM series will only work on OS images that support NVMe. If your current OS image doesn't have NVMe support, you’ll see an error message. [NVMe](../../enable-nvme-interface) support is available on the most popular OS images, and we're continuously improving OS image compatibility.

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
