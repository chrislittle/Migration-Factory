# Eb family VM size series - Azure Virtual Machines | Microsoft Learn

**Applies to:** ✔️ Linux VMs ✔️ Windows VMs ✔️ Flexible scale sets ✔️ Uniform scale sets

The 'Eb' family of VM size series are one of Azure's memory-optimized VM instances. They're designed for memory-intensive workloads with high remote storage performance, such as large databases, big data analytics, and enterprise applications that require significant amounts of RAM to maintain high performance. Equipped with high memory-to-core ratios, Eb-series VMs support applications and services that benefit from faster data access and more efficient data processing capabilities. This makes them particularly well-suited for scenarios involving in-memory databases and extensive data processing tasks where ample memory is crucial for optimal performance.

## Workloads and use cases

**Memory-Intensive Workloads:** Eb-family VMs are for workloads that demand a large memory footprint to efficiently handle tasks, such as simulations, large-scale computations in scientific research, or financial risk modeling.

**Large Databases and SQL Servers:** Eb-family VMs are ideal for hosting large relational databases like SQL Server and NoSQL databases that benefit from high memory capacities for improved performance in data processing and transaction handling.

**Enterprise Applications:** Eb-family VMs are suitable for resource-intensive enterprise applications, including large-scale ERP and CRM systems, where the availability of ample memory is crucial for managing complex transactions and user loads.

**Big Data Applications:** Eb-family VMs are effective for big data analytics applications that need to process vast amounts of data in memory to speed up analysis and insights generation.

**In-Memory Computing:** Eb-family VMs are great for in-memory databases (e.g., SAP HANA) that require large amounts of RAM to keep the entire dataset in memory, allowing for ultra-fast data processing and query responses.

**Data Warehousing:** Eb-family VMs provide the necessary resources for data warehousing solutions that handle and analyze large datasets, improving query performance and reducing response times.

## Series in family

### Ebsv6 and Ebdsv6-series

# [Ebsv6-series](#tab/ebsv6)
The Ebsv6-series virtual machines run on the fifth Generation Intel® Xeon® Platinum 8573C (Emerald Rapids) processor and deliver higher remote storage performance compared to the previous generation. The Ebsv6-series is ideal for storage throughput intensive workloads. These virtual machines offer up to 800,000 IOPS and 12,500 MBps of remote disk storage performance. Additionally, the Ebsv6 VM series offer up to 192vCPU and 1,832 GiB of RAM providing larger processing power to consolidate workloads. Refer to the Premium SSD, Premium SSD v2, and Ultra Disks to attain published disk performance.

[View the full Ebsv6-series page](ebsv6-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 192 vCPUs | Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 16 - 1832 GiB |  |
| Local Storage | None |  |
| Remote Storage | 8 - 64 Disks | 8800 - 800000 IOPS  253 - 12500 MBps |
| Network | 2 - 8 NICs | 12500 - 200000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Ebdsv6-series](#tab/ebdsv6)
The Ebdsv6-series virtual machines run on the fifth Generation Intel® Xeon® Platinum 8573C (Emerald Rapids) processor and deliver higher remote storage performance compared to the previous generation. The Ebdsv6-series is ideal for storage throughput intensive workloads. These virtual machines offer up to 800,000 IOPS and 12,500 MBps of remote disk storage performance. Additionally, the Ebdsv6 VM series offer up to 192vCPU and 1,832 GiB of RAM providing larger processing power to consolidate workloads. Refer to the Premium SSD, Premium SSD v2, and Ultra Disks to attain published disk performance.

[View the full Ebdsv6-series page](ebdsv6-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 192 vCPUs | Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 16 - 1832 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 1760 GiB  37500 - 3600000 IOPS 180 - 17280 MBps |
| Remote Storage | 8 - 64 Disks | 8800 - 800000 IOPS  253 - 12500 MBps |
| Network | 2 - 8 NICs | 12500 - 200000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Ebdsv5 and Ebsv5-series

The Ebdsv5 and Ebsv5 series run on the Intel® Xeon® Platinum 8573C (Emerald Rapids) or the Intel® Xeon® Platinum 8370C (Ice Lake) processors in a hyper-threaded configuration. The series are ideal for various memory-intensive enterprise applications. The Ebsv5 and Ebdsv5 VMs offer up to 260000 IOPS and 8000 MBps of remote disk storage throughput. Both series also include up to 672 GiB of RAM. The Ebdsv5 series has local SSD storage up to 3800 GiB. Both series provide a 3X increase in remote storage performance of data-intensive workloads compared to prior VM generations. You can use these series to consolidate existing workloads on fewer VMs or smaller VM sizes while achieving potential cost savings. The Ebdsv5 series comes with a local disk and Ebsv5 is without a local disk. We recommend choosing Premium SSD, Premium SSD v2 or Ultra Disks to attain the published disk performance.

[View the full Ebdsv5 and Ebsv5-series page](ebdsv5-ebsv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 112^vCores^ | Intel® Xeon® Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 16 - 672^GiB^ |  |
| Data Disks | 4 - 64^Disks^ | 5500 - 450000^IOPS^ / 125 - 8000^MBps^ |
| Network | 2 - 8^NICs^ | 12500 - 40000^Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1)^ |
| Accelerators | None |  |

### End of Life Eb family series

For End of Life sizes, see [End of Life sizes](../lifecycle/end-of-life-sizes-list#memory-optimized-end-of-life-sizes).

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
