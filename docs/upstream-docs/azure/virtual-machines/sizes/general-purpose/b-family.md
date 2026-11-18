# B family VM size series - Azure Virtual Machines | Microsoft Learn

**Applies to:** ✔️ Linux VMs ✔️ Windows VMs ✔️ Flexible scale sets ✔️ Uniform scale sets

The 'B' family of VM size series are one of Azure's general purpose VM instances. While traditional Azure virtual machines provide fixed CPU performance, B-series virtual machines are the only VM type that use credits for CPU performance provisioning. B-series VMs utilize a CPU credit model to track how much CPU is consumed - the virtual machine accumulates CPU credits when a workload is operating below the base CPU performance threshold and uses credits when running above the base CPU performance threshold until all of its credits are consumed. Upon consuming all the CPU credits, a B-series virtual machine is throttled back to its base CPU performance until it accumulates the credits to CPU burst again.

Read more about the [B-series CPU credit model](../../b-series-cpu-credit-model/b-series-cpu-credit-model).

## Workloads and use cases

**Usage Flexibility:** B-family VMs are best suited for workloads that do not require constant full CPU performance.

**Ideal Applications:** B-family VMs are ideal applications include web servers, proof of concepts, small databases, and development build environments.

**Performance Needs:** Some workloads often have burstable performance requirements, meaning they only need high performance sporadically. B-family VMs are perfect for this use case.

## Series in family

### Basv2-series

Basv2-series virtual machines run on the AMD's third Generation EPYC™ 7763v processor in a multi-threaded configuration with up to 256 MB L3 cache configuration. This series provides low cost CPU burstable general purpose virtual machines. Basv2-series virtual machines utilize a CPU credit model to track how much CPU is consumed. The virtual machine accumulates CPU credits when a workload is operating below the base CPU performance threshold and uses credits when running above the base CPU performance threshold, until all of its credits are consumed. Upon consuming all the CPU credits, a Basv2-series virtual machine is throttled back to its base CPU performance until it accumulates the credits to CPU burst again.

Basv2-series virtual machines offer a balance of compute, memory, and network resources, and are a cost effective way to run a broad spectrum of general purpose workloads. These include large scale micro-services, small and medium databases, virtual desktops, and business-critical applications. This series also offers an affordable option to run your code repositories and dev/test environments. Basv2-Series offers virtual machines of up-to 32 vCPU and 128 Gib of RAM, with max network bandwidth of upto 6,250 Mbps and max uncached disk throughput of 600 Mbps. Basv2-series virtual machines also support attachments of Standard SSD, Standard HDD, Premium SSD types with a default Remote-SSD support. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Basv2-series page](basv2-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 32 vCPUs | AMD EPYC 7763v (Milan) [x86-64] |
| Memory | 1 - 128 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 4,000 - 26,000 IOPS 85 - 600 MBps Disk Types: [Premium SSD](../../disks-types#premium-ssds) |
| Network | 2 - 4 NICs | 6,250 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

### Bpsv2-series

The Bpsv2-series virtual machines are based on the Arm architecture, featuring the Ampere® Altra® Arm-based processor operating at 3.0 GHz, delivering outstanding price-performance for general-purpose workloads. These virtual machines offer a range of VM sizes, from 0.5 GiB to up to 4 GiB of memory per vCPU, to meet the needs of applications that don't need the full performance of the CPU continuously, such as development and test servers, low traffic web servers, small databases, micro services, servers for proof-of-concepts, build servers, and code repositories. These workloads typically have burstable performance requirements. The Bpsv2-series VMs provides you with the ability to purchase a VM size with baseline performance that can build up credits when it's using less than its baseline performance. When the VM has accumulated credits, the VM can burst above the baseline using up to 100% of the vCPU when your application requires higher CPU performance.

[View the full Bpsv2-series page](bpsv2-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 16 vCPUs | Ampere Altra [Arm64] |
| Memory | 1 - 64 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 4,000 - 26,000 IOPS 85 - 600 MBps Disk Types: [Premium SSD](../../disks-types#premium-ssds) |
| Network | 2 - 4 NICs | 6,250 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

### Bsv2-series

Bsv2-series virtual machines run on Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8473C (Sapphire Rapids), or Intel® Xeon® Platinum 8370C (Ice Lake) processor in a hyper threaded configuration, providing low-cost CPU burstable general purpose virtual machines. Bsv2-series virtual machines utilize a CPU credit model to track how much CPU is consumed. The virtual machine accumulates CPU credits when a workload is operating below the base CPU performance threshold and, uses credits when running above the base CPU performance threshold until all of its credits are consumed. Upon consuming all the CPU credits, a Bsv2-series virtual machine is throttled back to its base CPU performance until it accumulates the credits to CPU burst again.

Bsv2-series virtual machines offer a balance of compute, memory, and network resources and are a cost-effective way to run a broad spectrum of general-purpose workloads. These include large-scale micro-services, small and medium databases, virtual desktops, and business-critical applications; and are also an affordable option to run your code repositories and dev/test environments. Bsv2-series offers virtual machines of up to 32 vCPU and 128 GiB of RAM, with max network bandwidth of up to 6,250 Mbps and max uncached disk throughput of 600 Mbps. Bsv2-series virtual machines also support attachments of Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Bsv2-series page](bsv2-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 32 vCPUs | Intel Xeon Platinum 8473C (Sapphire Rapids) [x86-64] Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 1 - 128 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 4,000 - 51,000 IOPS 85 - 600 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds) |
| Network | 2 - 4 NICs | 6,250 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

### End of Life B family series

For End of Life sizes, see [End of Life sizes](../lifecycle/end-of-life-sizes-list#general-purpose-end-of-life-sizes).

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
