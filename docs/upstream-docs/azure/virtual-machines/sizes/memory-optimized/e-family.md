# E family VM size series - Azure Virtual Machines | Microsoft Learn

**Applies to:** ✔️ Linux VMs ✔️ Windows VMs ✔️ Flexible scale sets ✔️ Uniform scale sets

The 'E' family of VM size series are one of Azure's memory-optimized VM instances. They're designed for memory-intensive workloads, such as large databases, big data analytics, and enterprise applications that require significant amounts of RAM to maintain high performance. Equipped with high memory-to-core ratios, E-series VMs support applications and services that benefit from faster data access and more efficient data processing capabilities. This makes them particularly well-suited for scenarios involving in-memory databases and extensive data processing tasks where ample memory is crucial for optimal performance.

## Workloads and use cases

**Memory-Intensive Workloads:** E-family VMs are for workloads that demands a large memory footprint to efficiently handle tasks, such as simulations, large-scale computations in scientific research, or financial risk modeling.

**Large Databases and SQL Servers:** E-family VMs are ideal for hosting large relational databases like SQL Server and NoSQL databases that benefit from high memory capacities for improved performance in data processing and transaction handling.

**Enterprise Applications:** E-family VMs are suitable for resource-intensive enterprise applications, including large-scale ERP and CRM systems, where the availability of ample memory is crucial for managing complex transactions and user loads.

**Big Data Applications:** E-family VMs are effective for big data analytics applications that need to process vast amounts of data in memory to speed up analysis and insights generation.

**In-Memory Computing:** E-family VMs are great for in-memory databases (e.g., SAP HANA) that require large amounts of RAM to keep the entire dataset in memory, allowing for ultra-fast data processing and query responses.

**Data Warehousing:** E-family VMs provide the necessary resources for data warehousing solutions that handle and analyze large datasets, improving query performance and reducing response times.

## Series in family

### Esv7 and Edsv7-series

# [Esv7 series](#tab/esv7)
Esv7-series virtual machines run on the Intel® Xeon® 6973PC (Granite Rapids) processor, reaching an all-core turbo clock speed of 3.6 GHz with a maximum turbo frequency of 4.2 GHz. This new processor features [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html), and [Intel® Advanced Matrix Extensions](https://www.intel.com/content/www/us/en/products/docs/accelerator-engines/advanced-matrix-extensions/overview.html). These virtual machines offer up to 372 vCPUs and 2,832 GiB of RAM. Esv7-series virtual machines are ideal for memory-intensive workloads, such as relational database servers, large databases, data analytics engines, in-memory caches, and more.Esv7-series virtual machines provide better performance for most general-purpose workloads compared to the prior generation, for example increased networking, increased remote storage performance, upgraded CPU, and elevated memory bandwidth.

Esv7-series virtual machines are ideal for memory-intensive workloads, such as SQL and NoSQL database servers, data analytics engines, data warehousing workloads, business intelligence applications, in-memory databases such as SAP and Redis, and in-memory analytics and more.

[View the full Esv7-series page](esv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 372 vCPUs | Intel@ Xeon® 6 processor 6973P-C(Granite Rapids) [x86-64] |
| Memory | 16 - 2,832 GiB |  |
| Local Storage | None |  |
| Remote Storage [Premium SSD](../../disks-types#premium-ssds) | 10 - 64 Disks | 4,000 - 500,000 IOPS 115 - 16,000 MBps |
| Remote Storage [Premium SSD v2](../../disks-types#premium-ssd-v2) / [Ultra Disks](../../disks-types#ultra-disks) | 10 - 64 Disks | 5,000 - 800,000 IOPS 135 - 20,000 MBps |
| Network | 3 - 15 NICs | 16,000 - 400,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Edsv7 series](#tab/edsv7)
Edsv7-series virtual machines run on the Intel® Xeon® 6 6973PC (Granite Rapids) processor reaching an all-core turbo clock speed of 3.6 GHz with a maximum turbo frequency of 4.2 GHz. This new processor features [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html), and [Intel® Advanced Matrix Extensions](https://www.intel.com/content/www/us/en/products/docs/accelerator-engines/advanced-matrix-extensions/overview.html). These virtual machines offer up to 372 vCPUs and 2,832 GiB of RAM. Edsv7-series virtual machines provide better performance for most general-purpose workloads compared to the prior generation, for example increased networking, increased remote storage performance, upgraded CPU, elevated memory bandwidth, faster NVMe local storage access, increased scalability, and larger local storage capacity.

Edsv7-series virtual machines are ideal for memory-intensive workloads, such as SQL and NoSQL database servers, data analytics engines, data warehousing workloads, business intelligence applications, in-memory databases such as SAP and Redis, and in-memory analytics and more.

[View the full Edsv7-series page](edsv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 372 vCPUs | Intel@ Xeon® 6 6973P-C (Granite Rapids) [x86-64] |
| Memory | 16 - 2,832 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 3,520 GiB  50,000 - 9,600,000 IOPS 280 - 53,760 MBps |
| Remote Storage [Premium SSD](../../disks-types#premium-ssds) | 10 - 64 Disks | 4,000 - 500,000 IOPS 115 - 16,000 MBps |
| Remote Storage [Premium SSD v2](../../disks-types#premium-ssd-v2) / [Ultra Disks](../../disks-types#ultra-disks) | 10 - 64 Disks | 5,000 - 800,000 IOPS 135 - 20,000 MBps |
| Network | 3 - 15 NICs | 16,000 - 400,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Easv7 series and Eadsv7 series

# [Easv7 series](#tab/easv7)
Easv7-series VMs utilize AMD's 5th Generation EPYC™ 9005 processors that can achieve a boosted maximum frequency of up to 4.5 GHz. These virtual machines offer up to 160 vCPU and 1280 GiB of RAM. The Easv7-series sizes offer a combination of vCPU and memory that is ideal for memory-intensive enterprise applications. The new VMs with no local disk provide a better value proposition for workloads that don't require local temporary storage.

[View the full Easv7-series page](easv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 160 vCPUs | AMD EPYC 9005 (Turin) [x86-64] |
| Memory | 16 - 1280 GiB |  |
| Local Storage | None |  |
| Remote Storage [Premium SSD](../../disks-types#premium-ssds) | 10 - 64 Disks | 4000 - 212000 IOPS 118 - 10344 MBps |
| Remote Storage [Premium SSD v2](../../disks-types#premium-ssd-v2) / [Ultra Disks](../../disks-types#ultra-disks) | 10 - 64 Disks | 4400 - 310000 IOPS 136 - 10356 MBps |
| Network | 2 - 15 NICs | 16000 - 80000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Eadsv7 series](#tab/eadsv7)
Eadsv7-series VMs utilize AMD's 5th Generation EPYC™ 9005 processors that can achieve a boosted maximum frequency of up to 4.5 GHz. These virtual machines offer up to 160 vCPU and 1280 GiB of RAM. The Eadsv7-series sizes offer a combination of vCPU, memory, and fast local NVMe temporary storage that is ideal for memory-intensive enterprise applications. Eadsv7-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Eadsv7-series page](eadsv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 160 vCPUs | AMD EPYC 9005 (Turin) [x86-64] |
| Memory | 16 - 1280 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 2200 GiB 37500 - 3000000 IOPS 280 - 22400 MBps |
| Remote Storage [Premium SSD](../../disks-types#premium-ssds) | 10 - 64 Disks | 4000 - 212000 IOPS 118 - 10344 MBps |
| Remote Storage [Premium SSD v2](../../disks-types#premium-ssd-v2) / [Ultra Disks](../../disks-types#ultra-disks) | 10 - 64 Disks | 4400 - 310000 IOPS 136 - 10356 MBps |
| Network | 2 - 15 NICs | 16000 - 80000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Ebsv6 and Ebdsv6-series

# [Ebsv6-series](#tab/ebsv6)
The Ebsv6-series virtual machines run on the fifth Generation Intel® Xeon® Platinum 8573C (Emerald Rapids) processor and deliver higher remote storage performance compared to the previous generation. The Ebsv6-series is ideal for storage throughput intensive workloads. These virtual machines offer up to 800,000 IOPS and 14,000 MBps of remote disk storage performance. Additionally, the Ebsv6 VM series offer up to 192vCPU and 1,832 GiB of RAM providing larger processing power to consolidate workloads. Refer to the Premium SSD, Premium SSD v2, and Ultra Disks to attain published disk performance.

[View the full Ebsv6-series page](ebsv6-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 192 vCPUs | Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 16 - 1832 GiB |  |
| Local Storage | None |  |
| Remote Storage | 8 - 64 Disks | 8800 - 800000 IOPS  253 - 14000 MBps |
| Network | 2 - 8 NICs | 12500 - 200000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Ebdsv6-series](#tab/ebdsv6)
The Ebdsv6-series virtual machines run on the fifth Generation Intel® Xeon® Platinum 8573C (Emerald Rapids) processor and deliver higher remote storage performance compared to the previous generation. The Ebdsv6-series is ideal for storage throughput intensive workloads. These virtual machines offer up to 800,000 IOPS and 14,000 MBps of remote disk storage performance. Additionally, the Ebsv6 VM series offer up to 192vCPU and 1,832 GiB of RAM providing larger processing power to consolidate workloads. Refer to the Premium SSD, Premium SSD v2, and Ultra Disks to attain published disk performance.

[View the full Ebdsv6-series page](ebdsv6-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 192 vCPUs | Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 16 - 1832 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 1760 GiB  37500 - 3600000 IOPS 180 - 17280 MBps |
| Remote Storage | 8 - 64 Disks | 8800 - 800000 IOPS  253 - 14000 MBps |
| Network | 2 - 8 NICs | 12500 - 200000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Epsv6 and Epdsv6-series

# [Epsv6-series](#tab/epsv6)
The Epsv6-series virtual machines are powered by Azure’s first-generation Cobalt 100 processor, delivering outstanding performance for memory optimized workloads. The Azure Cobalt 100 processor operates at 3.4 GHz and provides an entire physical core for each virtual machine vCPU. These virtual machines offer 8 GiB of memory per vCPU and a wide range of vCPU sizes. These VMs are best suited for memory-intensive scale-out and enterprise workloads, such as relational database servers, large databases, data analytics engines, in-memory caches, and more. Epsv6-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines. For more information, [see pricing for disks](https://azure.microsoft.com/pricing/details/managed-disks/). Epsv6-series virtual machines offer up to 96 vCPU and 672 GiB of RAM. These VMs come without local disk, providing a better value proposition for workloads that don't require local temporary storage.

[View the full Epsv6-series page](epsv6-series).

| Part | QuantityCount Units | SpecsSKU ID, Performance Units, etc. |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | Azure Cobalt 100 [ARM-64] |
| Memory | 16 - 672 GiB |  |
| Local Storage | None |  |
| Remote Storage [Premium SSD](../../disks-types#premium-ssds) | 8 - 64 Disks | 3750 - 153600 IOPS 106 - 5000 MBps |
| Remote Storage [Premium SSD v2](../../disks-types#premium-ssd-v2) / [Ultra Disks](../../disks-types#ultra-disks) | 8 - 64 Disks | 4163 - 199987 IOPS 124 - 5850 MBps |
| Network | 2 - 8 NICs | 12500 - 60000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Epdsv6-series](#tab/epdsv6)
The Epdsv6-series virtual machines are powered by Azure’s first-generation Cobalt 100 processor, delivering outstanding performance for memory optimized workloads. The Azure Cobalt 100 processor operates at 3.4 GHz and provides an entire physical core for each virtual machine vCPU. These virtual machines offer 8 GiB of memory per vCPU and a wide range of vCPU sizes. These VMs are best suited for memory-intensive scale-out and enterprise workloads, such as relational database servers, large databases, data analytics engines, in-memory caches, and more. Epdsv6-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines. For more information, [see pricing for disks](https://azure.microsoft.com/pricing/details/managed-disks/). Epdsv6-series virtual machines offer up to 96 vCPU, up to 672 GiB of RAM, and up to 5,280 GiB of fast local NVMe temporary storage.

[View the full Epdsv6-series page](epdsv6-series).

| Part | QuantityCount Units | SpecsSKU ID, Performance Units, etc. |
| --- | --- | --- |
| Processor | 2 - 96 vCores | Azure Cobalt 100 [ARM-64] |
| Memory | 16 - 672 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 880 GiB/Disk 15000 - 1800000 IOPS  90 - 8640 MBps |
| Remote Storage [Premium SSD](../../disks-types#premium-ssds) | 8 - 64 Disks | 3750 - 153600 IOPS 106 - 5000 MBps |
| Remote Storage [Premium SSD v2](../../disks-types#premium-ssd-v2) / [Ultra Disks](../../disks-types#ultra-disks) | 8 - 64 Disks | 4163 - 199987 IOPS 124 - 5850 MBps |
| Network | 2 - 8 NICs | 12500 - 60000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Easv6 and Eadsv6-series

# [Easv6-series](#tab/easv6)
Easv6-series VMs utilize AMD's fourth Generation EPYC™ 9004 processors that can achieve a boosted maximum frequency of 3.7 GHz. These virtual machines offer up to 96 vCPU and 672 GiB of RAM. The Easv6-series sizes offer a combination of vCPU and memory that is ideal for memory-intensive enterprise applications. The new VMs with no local disk provide a better value proposition for workloads that don't require local temporary storage.

[View the full Easv6-series page](easv6-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | AMD EPYC 9004 (Genoa) [x86-64] |
| Memory | 16 - 672 GiB |  |
| Local Storage | None |  |
| Remote Storage [Premium SSD](../../disks-types#premium-ssds) | 4 - 32 Disks | 4000 - 175000 IOPS 90 - 4320 MBps |
| Remote Storage [Premium SSD v2](../../disks-types#premium-ssd-v2) / [Ultra Disks](../../disks-types#ultra-disks) | 4 - 32 Disks | 4000 - 175000 IOPS 90 - 4320 MBps |
| Network | 2 - 8 NICs | 12500 - 40000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

# [Eadsv6-series](#tab/eadsv6)
Eadsv6-series VMs utilize AMD's fourth Generation EPYC™ 9004 processors that can achieve a boosted maximum frequency of 3.7 GHz. These virtual machines offer up to 96 vCPU and 672 GiB of RAM. The Eadsv6-series sizes offer a combination of vCPU, memory, and fast local NVMe temporary storage that is ideal for memory-intensive enterprise applications. Eadsv6-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Eadsv6-series page](eadsv6-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | AMD EPYC 9004 (Genoa) [x86-64] |
| Memory | 16 - 672 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 880 GiB 37500 - 1800000 IOPS 180 - 8640 MBps |
| Remote Storage [Premium SSD](../../disks-types#premium-ssds) | 4 - 32 Disks | 4000 - 175000 IOPS 90 - 4320 MBps |
| Remote Storage [Premium SSD v2](../../disks-types#premium-ssd-v2) / [Ultra Disks](../../disks-types#ultra-disks) | 4 - 32 Disks | 4000 - 175000 IOPS 90 - 4320 MBps |
| Network | 2 - 8 NICs | 12500 - 40000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

---

### Ev5 and Esv5-series

# [Ev5-series](#tab/ev5)
Ev5-series virtual machines run on Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8473C (Sapphire Rapids) or Intel® Xeon® Platinum 8370C (Ice Lake) processor in a [hyper threaded](https://www.intel.com/content/www/us/en/gaming/resources/hyper-threading.html) configuration. This new processor features an all core turbo clock speed of 3.5 GHz with [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html) and [Intel® Deep Learning Boost](https://software.intel.com/content/www/us/en/develop/topics/ai/deep-learning-boost.html). These virtual machines offer up to 104 vCPU and 672 GiB of RAM. Esv5-series virtual machines don't have temporary storage thus lowering the price of entry.

Ev5-series supports Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Ev5-series page](ev5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 104 vCPUs | Intel Xeon Platinum 8473C (Sapphire Rapids) [x86-64] Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 16 - 672 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 64 Disks | 3750 - 120000 IOPS 85 - 4000 MBps |
| Network | 2 - 8 NICs | 12500 - 100000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Esv5-series](#tab/esv5)
Esv5-series virtual machines run on Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8473C (Sapphire Rapids) or Intel® Xeon® Platinum 8370C (Ice Lake) processor in a [hyper threaded](https://www.intel.com/content/www/us/en/gaming/resources/hyper-threading.html) configuration. This new processor features an all core turbo clock speed of 3.5 GHz with [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html) and [Intel® Deep Learning Boost](https://software.intel.com/content/www/us/en/develop/topics/ai/deep-learning-boost.html). These virtual machines offer up to 104 vCPU and 672 GiB of RAM. Esv5-series virtual machines don't have temporary storage thus lowering the price of entry.

Esv5-series supports Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Esv5-series page](esv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 104 vCPUs | Intel Xeon Platinum 8473C (Sapphire Rapids) [x86-64] Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 16 - 672 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 64 Disks | 3750 - 120000 IOPS 85 - 4000 MBps |
| Network | 2 - 8 NICs | 12500 - 100000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Edv5 and Edsv5-series

# [Edv5-series](#tab/edv5)
Edv5-series virtual machines run on the Intel® Xeon® Platinum 8573C (Emerald Rapids) or the Intel® Xeon® Platinum 8370C (Ice Lake) processor in a [hyper threaded](https://www.intel.com/content/www/us/en/gaming/resources/hyper-threading.html) configuration. This new processor features an all core turbo clock speed of 3.5 GHz with [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html) and [Intel® Deep Learning Boost](https://software.intel.com/content/www/us/en/develop/topics/ai/deep-learning-boost.html). These virtual machines offer up to 104 vCPU and 672 GiB of RAM and fast, local SSD storage up to 3800 GiB. Edv5-series virtual machines are ideal for memory-intensive enterprise applications and applications that benefit from low latency, high-speed local storage.

Edv5-series virtual machines support Standard SSD and Standard HDD types. To use Premium SSD or Ultra Disk storage, select Edsv5-series virtual machines. Disk storage is billed separately from virtual machines.

[View the full Edv5-series page](edv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 104 vCPUs | Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 16 - 672 GiB |  |
| Local Storage | 1 Disk | 75 - 3800 GiB 9000 - 450000 IOPS 125 - 4000 MBps |
| Remote Storage | 4 - 64 Disks | 3750 - 120000 IOPS 85 - 4000 MBps |
| Network | 2 - 8 NICs | 12500 - 100000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Edsv5-series](#tab/edsv5)
Edsv5-series virtual machines run on the Intel® Xeon® Platinum 8573C (Emerald Rapids) or the Intel® Xeon® Platinum 8370C (Ice Lake) processor in a [hyper threaded](https://www.intel.com/content/www/us/en/gaming/resources/hyper-threading.html) configuration. This new processor features an all core turbo clock speed of 3.5 GHz with [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html) and [Intel® Deep Learning Boost](https://software.intel.com/content/www/us/en/develop/topics/ai/deep-learning-boost.html). These virtual machines offer up to 104 vCPU and 672 GiB of RAM and fast, local SSD storage up to 3800 GiB. Edsv5-series virtual machines are ideal for memory-intensive enterprise applications and applications that benefit from low latency, high-speed local storage.

Edsv5-series virtual machines support Standard SSD and Standard HDD types. You can attach Standard SSD, Standard HDD, and Premium SSD storage to these VMs. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines. See pricing for disks. The Edsv5-series virtual machines can burst their disk performance and get up to their bursting max for up to 30 minutes at a time.

[View the full Edsv5-series page](edsv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 104 vCPUs | Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 16 - 672 GiB |  |
| Local Storage | 1 Disk | 75 - 3800 GiB 9000 - 450000 IOPS 125 - 4000 MBps |
| Remote Storage | 4 - 64 Disks | 3750 - 120000 IOPS 85 - 4000 MBps |
| Network | 2 - 8 NICs | 12500 - 100000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Easv5 and Eadsv5-series

# [Easv5-series](#tab/easv5)
Easv5-series utilize AMD's 3rd Generation EPYC™ 7763v and AMD's 4th Generation EPYC™ 9004 processors. The Easv5-series sizes offer a combination of vCPU and memory that is ideal for memory-intensive enterprise applications. The new VMs with no local disk provide a better value proposition for workloads that don't require local temp disk. Easv5-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Easv5-series page](easv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 112 vCPUs | AMD EPYC 7763v (Milan) [x86-64] , AMD EPYC 9004 (Genoa) [x86-64] |
| Memory | 16 - 672 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 64 Disks | 3750 - 120000 IOPS 82 - 2000 MBps |
| Network | 2 - 8 NICs | 12500 - 50000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

# [Eadsv5-series](#tab/eadsv5)
Eadsv5-series utilize AMD's 3rd Generation EPYC™ 7763v and AMD's 4th Generation EPYC™ 9004 processors. The Eadsv5-series sizes offer a combination of vCPU, memory, and temporary storage that is ideal for memory-intensive enterprise applications. The new VMs have 50% larger local storage, and better local disk IOPS for both read and write compared to the Eav4/Easv4 sizes with Gen2 VMs. Eadsv5-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Eadsv5-series page](eadsv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 112 vCPUs | AMD EPYC 7763v (Milan) [x86-64] , AMD EPYC 9004 (Genoa) [x86-64] |
| Memory | 16 - 672 GiB |  |
| Local Storage | 1 Disk | 75 - 3800 GiB 9000 - 450000 IOPS 125 - 4000 MBps |
| Remote Storage | 4 - 64 Disks | 3750 - 120000 IOPS 82 - 2000 MBps |
| Network | 2 - 8 NICs | 12500 - 50000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

---

### Epsv5 and Epdsv5-series

# [Epsv5-series](#tab/epsv5)
Epsv5-series virtual machines feature the Ampere® Altra® Arm-based processor operating at 3.0 GHz, which provides an entire physical core for each virtual machine vCPU. These virtual machines offer up to 32 vCPU and 208 GiB of RAM and are ideal for memory-intensive scale-out and most Enterprise workloads. Epsv5-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types with no local-SSD support. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Epsv5-series page](epsv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 32 vCPUs | Ampere Altra [ARM-64] |
| Memory | 16 - 208 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 3750 - 51200 IOPS 85 - 865 MBps |
| Network | 2 - 8 NICs | 12500 - 16000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

# [Epdsv5-series](#tab/epdsv5)
Epdsv5-series virtual machines feature the Ampere® Altra® Arm-based processor operating at 3.0 GHz, which provides an entire physical core for each virtual machine vCPU. These virtual machines offer up to 32 vCPU, 208 GiB of RAM, and fast local SSD storage up to 1,200 GiB and are ideal for memory-intensive scale-out and most Enterprise workloads. Epdsv5-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Epdsv5-series page](epdsv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 32 vCPUs | Ampere Altra [ARM-64] |
| Memory | 16 - 208 GiB |  |
| Local Storage | 1 Disk | 75 - 1200 GiB 9375 - 150000 IOPS 125 - 2000 MBps |
| Remote Storage | 4 - 32 Disks | 3750 - 51200 IOPS 85 - 865 MBps |
| Network | 2 - 8 NICs | 12500 - 16000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

---

### End of Life E family series

Warning

The [Ev3-series and Esv3-series](ev3-esv3-series) are in the [End of Life](../lifecycle/lifecycle-overview#end-of-life) lifecycle stage and retire on **November 15, 2029**. After that date, you can't create, resize into, run, or purchase any of the 18 Ev3-series and Esv3-series sizes. For the smoothest transition, see [Modernize to the v5 VM series](../lifecycle/sizes-v5-modernization-overview). For the latest features and performance, see [Modernize to the v6 and v7 VM series](../lifecycle/sizes-v6-v7-modernization-overview). For retirement details, see [Retired and retiring VM size series](../lifecycle/retirements-and-capacity-restrictions#memory-optimized-retired-sizes).

For End of Life sizes, see [End of Life sizes](../lifecycle/end-of-life-sizes-list#memory-optimized-end-of-life-sizes).

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
