# Easv4 size series - Azure Virtual Machines | Microsoft Learn

The Easv4-series run on 2nd Generation AMD EPYC™ 7452 (up to 3.35GHz) or 3rd Generation EPYC™ 7763v processors (up to 3.5GHz) and use Premium SSD. The Easv4-series sizes are ideal for memory-intensive enterprise applications.

## Host specifications

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | AMD EPYC 7452 (Rome) [x86-64] AMD EPYC 7763v (Milan) [x86-64] |
| Memory | 16 - 672 GiB |  |
| Local Storage | 1 Disk | 32 - 1344 GiB 4000 - 192000 IOPS 32 - 1020 MBps |
| Remote Storage | 4 - 32 Disks | 3200 - 80000 IOPS 48 - 1200 MBps |
| Network | 2 - 8 NICs | 2000 - 32000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

For features supported by this series, see the Feature support section.

## Sizes in series

# [Basics](#tab/sizebasic)
vCPUs (Qty.) and Memory for each size

| Size Name | vCPUs (Qty.) | Memory (GB) |
| --- | --- | --- |
| Standard\_E2as\_v4 | 2 | 16 |
| Standard\_E4as\_v4 | 4 | 32 |
| Standard\_E8as\_v4 | 8 | 64 |
| Standard\_E16as\_v4 | 16 | 128 |
| Standard\_E20as\_v4 | 20 | 160 |
| Standard\_E32as\_v4 | 32 | 256 |
| Standard\_E48as\_v4 | 48 | 384 |
| Standard\_E64as\_v4 | 64 | 512 |
| Standard\_E96as\_v4 | 96 | 672 |

#### VM Basics resources

- [Check vCPU quotas](../../quotas)

# [Local storage](#tab/sizestoragelocal)
Local (temp) storage info for each size

| Size Name | Max Temp Storage Disks (Qty.) | Temp Disk Size (GiB) | Temp Disk Random Read (RR)^1^IOPS | Temp Disk Random Read (RR)^1^Throughput (MB/s) | Temp Disk Random Write (RW)^1^Throughput (MB/s) |
| --- | --- | --- | --- | --- | --- |
| Standard\_E2as\_v4 | 1 | 32 | 4000 | 32 | 50 |
| Standard\_E4as\_v4 | 1 | 64 | 8000 | 64 | 100 |
| Standard\_E8as\_v4 | 1 | 128 | 16000 | 128 | 200 |
| Standard\_E16as\_v4 | 1 | 256 | 32000 | 255 | 400 |
| Standard\_E20as\_v4 | 1 | 320 | 40000 | 320 | 500 |
| Standard\_E32as\_v4 | 1 | 512 | 64000 | 510 | 800 |
| Standard\_E48as\_v4 | 1 | 768 | 96000 | 1020 | 1200 |
| Standard\_E64as\_v4 | 1 | 1024 | 128000 | 1020 | 1600 |
| Standard\_E96as\_v4 | 1 | 1344 | 192000 | 1020 | 2400 |

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
| Standard\_E2as\_v4 | 4 | 3200 | 48 | 4000 | 200 |
| Standard\_E4as\_v4 | 8 | 6400 | 96 | 8000 | 200 |
| Standard\_E8as\_v4 | 16 | 12800 | 192 | 16000 | 400 |
| Standard\_E16as\_v4 | 32 | 25600 | 384 | 32000 | 800 |
| Standard\_E20as\_v4 | 32 | 32000 | 480 | 40000 | 1000 |
| Standard\_E32as\_v4 | 32 | 51200 | 768 | 64000 | 1600 |
| Standard\_E48as\_v4 | 32 | 76800 | 1148 | 80000 | 2000 |
| Standard\_E64as\_v4 | 32 | 80000 | 1200 | 80000 | 2000 |
| Standard\_E96as\_v4 | 32 | 80000 | 1200 | 80000 | 2000 |

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
| Standard\_E2as\_v4 | 2 | 2000 |
| Standard\_E4as\_v4 | 2 | 4000 |
| Standard\_E8as\_v4 | 4 | 8000 |
| Standard\_E16as\_v4 | 8 | 10000 |
| Standard\_E20as\_v4 | 8 | 12000 |
| Standard\_E32as\_v4 | 8 | 16000 |
| Standard\_E48as\_v4 | 8 | 24000 |
| Standard\_E64as\_v4 | 8 | 32000 |
| Standard\_E96as\_v4 | 8 | 32000 |

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
