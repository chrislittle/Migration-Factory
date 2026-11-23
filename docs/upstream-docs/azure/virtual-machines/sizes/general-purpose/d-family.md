# D-family size series - Azure Virtual Machines | Microsoft Learn

**Applies to:** ✔️ Linux VMs ✔️ Windows VMs ✔️ Flexible scale sets ✔️ Uniform scale sets

The 'D' family of VM sizes are one of Azure's general purpose VM sizes. They're designed for a variety of demanding workloads, such as enterprise applications, web and application servers, development and test environments, and batch processing tasks. Equipped with faster processors and more memory per core than the A-series, D-series VMs offer a strong performance balance, making them suitable for applications that require both high computational power and substantial memory resources. They are particularly favored for running enterprise-grade applications, supporting moderate to high-traffic web servers, and performing data-intensive batch processing.

## Workloads and use cases

**Balanced Performance:** D-series VMs provide a solid balance between CPU capabilities and memory size, which makes them suitable for most production workloads. They are equipped with faster processors compared to the A-series and provide more memory per core.

**Enterprise Applications:** They are well-suited for running enterprise applications like SAP, Microsoft Dynamics, or large relational databases that require both high computational power and substantial memory.

**Development and Test Environments:** With their balanced resources, D-series VMs are ideal for development and testing environments where developers need to simulate production conditions closely.

**Web and Application Servers:** They provide the necessary resources to host web servers and application servers that experience moderate to heavy traffic, ensuring smooth and responsive user experiences.

**Batch Processing:** D-series VMs are efficient for handling batch processing tasks that require processing large amounts of data quickly, thanks to their fast processors and ample memory.

**Gaming Servers:** The high-performance capabilities of D-series VMs make them suitable for gaming servers where latency and speed are critical for a good user experience.

## Series in family

### Dpsv7 and Dpdsv7-series

# [Dpsv7-series](#tab/dpsv7)
The Dpsv7-series virtual machines are powered by Azure's second-generation Cobalt 200 processor, designed for general-purpose workloads. The Azure Cobalt 200 processor is based on the Arm Neoverse V3 architecture and provides an entire physical core for each virtual machine vCPU. Cobalt 200 supports the [Processor Mode](../../vm-processor-mode) feature, running at up to 3.6 GHz in Opportunistic mode and at 3.2 GHz in Deterministic mode. These virtual machines offer 4 GiB of memory per vCPU and a wide range of vCPU sizes.

These VMs are suited for scale-out enterprise workloads such as web and application servers, small to medium databases, and caches. Dpsv7-series virtual machines offer up to 128 vCPUs and 512 GiB of RAM. These VMs come without local disk, providing a better value proposition for workloads that don't require local temporary storage.

Dpsv7-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Premium SSD v2 and Ultra Disk storage. Disk storage is billed separately from virtual machines. For more information, see [pricing for disks](https://azure.microsoft.com/pricing/details/managed-disks/).

[View the full Dpsv7-series page](dpsv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 1 - 128 vCPUs | Azure Cobalt 200 [Arm64] |
| Memory | 4 - 512 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 64 Disks | 2,000 - 320,000 IOPS 60 - 8,770 MBps Disk Types: [Standard SSD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 15 NICs | 12,500 - 85,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Dpdsv7-series](#tab/dpdsv7)
The Dpdsv7-series virtual machines are powered by Azure's second-generation Cobalt 200 processor, designed for general-purpose workloads. The Azure Cobalt 200 processor is based on the Arm Neoverse V3 architecture and provides an entire physical core for each virtual machine vCPU. Cobalt 200 supports the [Processor Mode](../../vm-processor-mode) feature, running at up to 3.6 GHz in Opportunistic mode and at 3.2 GHz in Deterministic mode. These virtual machines offer 4 GiB of memory per vCPU and a wide range of vCPU sizes.

These VMs are suited for scale-out enterprise workloads such as web and application servers, small to medium databases, and caches. Dpdsv7-series virtual machines offer up to 128 vCPUs, 512 GiB of RAM, and 7,040 GiB of local NVMe temporary storage.

Dpdsv7-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Premium SSD v2 and Ultra Disk storage. Disk storage is billed separately from virtual machines. For more information, see [pricing for disks](https://azure.microsoft.com/pricing/details/managed-disks/).

[View the full Dpdsv7-series page](dpdsv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 1 - 128 vCPUs | Azure Cobalt 200 [Arm64] |
| Memory | 4 - 512 GiB |  |
| Local Storage | 1 - 6 Disks | 55 - 1,760 GiB 25,000 - 3,200,000 IOPS 180 - 23,040 MBps |
| Remote Storage | 4 - 64 Disks | 2,000 - 320,000 IOPS 60 - 8,770 MBps Disk Types: [Standard SSD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 15 NICs | 12,500 - 85,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Dplsv7 and Dpldsv7-series

# [Dplsv7-series](#tab/dplsv7)
The Dplsv7-series virtual machines are powered by Azure's second-generation Cobalt 200 processor, designed for general-purpose workloads. The Azure Cobalt 200 processor is based on the Arm Neoverse V3 architecture and provides an entire physical core for each virtual machine vCPU. Cobalt 200 supports the [Processor Mode](../../vm-processor-mode) feature, running at up to 3.6 GHz in Opportunistic mode and at 3.2 GHz in Deterministic mode. These virtual machines offer 2 GiB of memory per vCPU for workloads that need less memory relative to their compute requirements.

These VMs are suited for non-memory-intensive and scale-out workloads such as microservices, small databases, caches, and gaming servers. Dplsv7-series virtual machines offer up to 128 vCPUs and 256 GiB of RAM. These VMs come without local disk, providing a better value proposition for workloads that don't require local temporary storage.

Dplsv7-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Premium SSD v2 and Ultra Disk storage. Disk storage is billed separately from virtual machines. For more information, see [pricing for disks](https://azure.microsoft.com/pricing/details/managed-disks/).

[View the full Dplsv7-series page](dplsv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 1 - 128 vCPUs | Azure Cobalt 200 [Arm64] |
| Memory | 2 - 256 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 64 Disks | 2,000 - 320,000 IOPS 60 - 8,770 MBps Disk Types: [Standard SSD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 15 NICs | 12,500 - 85,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Dpldsv7-series](#tab/dpldsv7)
The Dpldsv7-series virtual machines are powered by Azure's second-generation Cobalt 200 processor, designed for general-purpose workloads. The Azure Cobalt 200 processor is based on the Arm Neoverse V3 architecture and provides an entire physical core for each virtual machine vCPU. Cobalt 200 supports the [Processor Mode](../../vm-processor-mode) feature, running at up to 3.6 GHz in Opportunistic mode and at 3.2 GHz in Deterministic mode. These virtual machines offer 2 GiB of memory per vCPU for workloads that need less memory relative to their compute requirements.

These VMs are suited for non-memory-intensive and scale-out workloads such as microservices, small databases, caches, and gaming servers. Dpldsv7-series virtual machines offer up to 128 vCPUs, 256 GiB of RAM, and 7,040 GiB of local NVMe temporary storage.

Dpldsv7-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Premium SSD v2 and Ultra Disk storage. Disk storage is billed separately from virtual machines. For more information, see [pricing for disks](https://azure.microsoft.com/pricing/details/managed-disks/).

[View the full Dpldsv7-series page](dpldsv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 1 - 128 vCPUs | Azure Cobalt 200 [Arm64] |
| Memory | 2 - 256 GiB |  |
| Local Storage | 1 - 6 Disks | 55 - 1,760 GiB 25,000 - 3,200,000 IOPS 180 - 23,040 MBps |
| Remote Storage | 4 - 64 Disks | 2,000 - 320,000 IOPS 60 - 8,770 MBps Disk Types: [Standard SSD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 15 NICs | 12,500 - 85,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Dsv7 series and Ddsv7 series

# [Dsv7 series](#tab/dsv7)
Dsv7-series virtual machines run on the Intel® Xeon® 6 6973PC (Granite Rapids) processor, reaching an all-core turbo clock speed of 3.6 GHz with a maximum turbo frequency of 4.2 GHz. This new processor features [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html), and [Intel® Advanced Matrix Extensions](https://www.intel.com/content/www/us/en/products/docs/accelerator-engines/advanced-matrix-extensions/overview.html). Dsv7-series virtual machines provide better performance for most general-purpose workloads compared to the prior generation for example increased networking, increased remote storage performance, upgraded CPU, and elevated memory bandwidth. Dsv7-series virtual machines are ideal for many general computing workloads such as e-commerce systems, web applications, desktop virtualization solutions, application servers, and more.

Dsv7-series virtual machines don't have any temporary storage thus lowering the price of entry. You can attach Standard SSDs, Standard HDDs, Premium SSDs, and Premium SSD v2 storage to these virtual machines. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Dsv7-series page](dsv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 372 vCPUs | Intel Xeon 6 6973PC (Granite Rapids) [x86-64] |
| Memory | 8 - 1,488 GiB |  |
| Local Storage | None |  |
| Remote Storage | 10 - 64 Disks | 4,000 - 500,000 IOPS 115 - 16,000 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2) |
| Network | 3 - 15 NICs | 16,000 - 200,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Ddsv7 series](#tab/ddsv7)
Ddsv7-series virtual machines run on the Intel® Xeon® 6 6973PC (Granite Rapids) processor reaching an all-core turbo clock speed of 3.6 GHz with a maximum turbo frequency is 4.2 GHz. This new processor features [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html), and [Intel® Advanced Matrix Extensions](https://www.intel.com/content/www/us/en/products/docs/accelerator-engines/advanced-matrix-extensions/overview.html). These virtual machines offer up to 372 vCPUs and 1,488 GiB of RAM. Ddsv7-series virtual machines provide better performance for most general-purpose workloads compared to the prior generation for example increased networking, increased remote storage performance, upgraded CPU, elevated memory bandwidth, faster NVMe local storage access, increased scalability, and larger local storage capacity. Ddsv7-series virtual machines are ideal for many general computing workloads such as e-commerce systems, web applications, desktop virtualization solutions, application servers, and more.

Ddsv7-series virtual machines offer local storage disks. You can attach Standard SSDs, Standard HDDs, Premium SSDs, and Premium SSD v2 storage to these virtual machines. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Ddsv7-series page](ddsv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 372 vCPUs | Intel Xeon 6 6973PC (Granite Rapids) [x86-64] |
| Memory | 8 - 1,488 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 3,520 GiB 50,000 - 9,600,000 IOPS 280 - 53,760 MBps |
| Remote Storage | 10 - 64 Disks | 4,000 - 500,000 IOPS 115 - 16,000 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2) |
| Network | 3 - 15 NICs | 16,000 - 200,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Dlsv7 series and Dldsv7 series

# [Dlsv7 series](#tab/dlsv7)
Dlsv7-series virtual machines run on Intel® Xeon® 6 6973PC (Granite Rapids) processor reaching an all-core turbo clock speed of 3.6 GHz with a maximum turbo frequency of 4.2 GHz. This new processor features [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html), and [Intel® Advanced Matrix Extensions](https://www.intel.com/content/www/us/en/products/docs/accelerator-engines/advanced-matrix-extensions/overview.html). These virtual machines offer up to 248 vCPUs and 496 GiB of RAM. Dlsv7-series virtual machines provide better performance for most general-purpose workloads compared to the prior generation, for example increased networking, increased remote storage performance, upgraded CPU, and elevated memory bandwidth. These virtual machine sizes can reduce costs when running non-memory intensive applications. Dlsv7-series virtual machines are ideal for many general computing workloads such as e-commerce systems, web applications, desktop virtualization solutions, application servers, and more.

Dlsv7-series virtual machines don't have any temporary storage, thus lowering the price of entry. You can attach Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines

[View the full Dlsv7-series page](dlsv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 248 vCPUs | Intel Xeon 6 6973PC (Granite Rapids) [x86-64] |
| Memory | 4 - 496 GiB |  |
| Local Storage | None |  |
| Remote Storage | 10 - 64 Disks | 4,000 - 397,000 IOPS 115 - 13,145 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 3 - 15 NICs | 16,000 - 150,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Dldsv7 series](#tab/dldsv7)
Dldsv7-series virtual machines run on the Intel® Xeon® 6 6973PC (Granite Rapids) processor reaching an all-core turbo clock speed of 3.6 GHz with a max turbo frequency of 4.2 GHz. This new processor features [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html), and [Intel® Advanced Matrix Extensions](https://www.intel.com/content/www/us/en/products/docs/accelerator-engines/advanced-matrix-extensions/overview.html). These virtual machines offer up to 248 vCPU and 496 GiB of RAM. Dldsv7-series virtual machines provide better performance for most general-purpose workloads compared to the prior generation with increased networking, increased remote storage performance, upgraded CPU performance, elevated memory bandwidth, faster NVMe local storage access, increased scalability, and larger local storage capacity. These virtual machine sizes can reduce cost when running non-memory intensive applications. Dldsv7-series virtual machines are ideal for many general computing workloads such as e-commerce systems, web applications, desktop virtualization solutions, application servers, and more.

Dldsv7-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Dldsv7-series page](dldsv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 248 vCPUs | Intel Xeon 6 6973PC (Granite Rapids) [x86-64] |
| Memory | 4 - 496 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 1,760 GiB 50,000 - 6,400,000 IOPS 280 - 35,840 MBps |
| Remote Storage | 10 - 64 Disks | 4,000 - 397,000 IOPS 115 - 13,145 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2) |
| Network | 3 - 15 NICs | 16,000 - 150,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Dasv7 series and Dadsv7 series

# [Dasv7 series](#tab/dasv7)
Dasv7-series VMs utilize AMD's 5th Generation EPYC™ 9005 processors that can achieve a boosted maximum frequency of up to 4.5 GHz. These virtual machines offer up to 160 vCPU and 640 GiB of RAM. The Dasv7-series sizes offer a combination of vCPU and memory for most production workloads. The new VMs with no local disk provide a better value proposition for workloads that don't require local temporary storage.

[View the full Dasv7-series page](dasv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 160 vCPUs | AMD EPYC 9005 (Turin) [x86-64] |
| Memory | 8 - 640 GiB |  |
| Local Storage | None |  |
| Remote Storage | 10 - 64 Disks | 4,000 - 310,000 IOPS 118 - 10,356 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2) |
| Network | 2 - 15 NICs | 16,000 - 80,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Dadsv7 series](#tab/dadsv7)
Dadsv7-series VMs utilize AMD's 5th Generation EPYC™ 9005 processors that can achieve a boosted maximum frequency of up to 4.5 GHz. These virtual machines offer up to 160 vCPU and 640 GiB of RAM. The Dadsv7-series sizes offer a combination of vCPU, memory and fast local NVMe temporary storage for most production workloads. Dadsv7-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Dadsv7-series page](dadsv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 160 vCPUs | AMD EPYC 9005 (Turin) [x86-64] |
| Memory | 8 - 640 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 2,200 GiB 38,000 - 3,000,000 IOPS 280 - 22,400 MBps |
| Remote Storage | 10 - 64 Disks | 4,000 - 310,000 IOPS 118 - 10,356 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2) |
| Network | 2 - 15 NICs | 16,000 - 80,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Dalsv7 series and Daldsv7 series

# [Dalsv7 series](#tab/dalsv7)
Dalsv7-series VMs utilize AMD's 5th Generation EPYC™ 9005 processors that can achieve a boosted maximum frequency of up to 4.5 GHz. These virtual machines offer up to 160 vCPU and 320 GiB of RAM. These VM sizes can reduce cost when running non-memory intensive applications. The new VMs with no local disk provide a better value proposition for workloads that don't require local temporary storage.

[View the full Dalsv7-series page](dalsv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 160 vCPUs | AMD EPYC 9005 (Turin) [x86-64] |
| Memory | 4 - 320 GiB |  |
| Local Storage | None |  |
| Remote Storage | 10 - 64 Disks | 4,000 - 310,000 IOPS 118 - 10,356 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2) |
| Network | 2 - 15 NICs | 16,000 - 80,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Daldsv7 series](#tab/daldsv7)
Daldsv7-series VMs utilize AMD's 5th Generation EPYC™ 9005 processors that can achieve a boosted maximum frequency of up to 4.5 GHz. These virtual machines offer up to 160 vCPUs, 320 GiB of RAM. The Daldsv7-series sizes offer a combination of vCPU, memory and fast local NVMe temporary storage for most production workloads. These VM sizes can reduce cost when running non-memory intensive applications. Daldsv7-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Daldsv7-series page](daldsv7-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 160 vCPUs | AMD EPYC 9005 (Turin) [x86-64] |
| Memory | 4 - 320 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 2,200 GiB 38,000 - 3,000,000 IOPS 280 - 22,400 MBps |
| Remote Storage | 10 - 64 Disks | 4,000 - 310,000 IOPS 118 - 10,356 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2) |
| Network | 2 - 15 NICs | 16,000 - 80,000 Mbps Interfaces: NetVSC, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Dpsv6 and Dplsv6-series

# [Dpsv6-series](#tab/dpsv6)
The Dpsv6-series virtual machines are powered by Azure's first-generation Cobalt 100 processor, delivering outstanding performance for general-purpose workloads. The Azure Cobalt 100 processor operates at 3.4 GHz and provides an entire physical core for each virtual machine vCPU. These virtual machines offer 4 GiB of memory per vCPU and a wide range of vCPU sizes. These VMs meet the requirements of most scale-out enterprise workloads such as web and application servers, small to medium databases, caches, and more. Dpsv6-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines. For more information, [see pricing for disks](https://azure.microsoft.com/pricing/details/managed-disks/). Dpsv6-series virtual machines offer up to 96 vCPU and 384 GiB of RAM. These VMs come without local disk, providing a better value proposition for workloads that don't require local temporary storage.

[View the full Dpsv6-series page](dpsv6-series).

| Part | QuantityCount Units | SpecsSKU ID, Performance Units, etc. |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | Azure Cobalt 100 [Arm64] |
| Memory | 8 - 384 GiB |  |
| Local Storage | None |  |
| Remote Storage | 8 - 64 Disks | 4,000 - 200,000 IOPS 106 - 5,850 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 8 NICs | 12,500 - 60,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Dplsv6-series](#tab/dplsv6)
The Dplsv6-series virtual machines are powered by Azure's first-generation Cobalt 100 processor, delivering outstanding performance for general-purpose workloads. The Azure Cobalt 100 processor operates at 3.4 GHz and provides an entire physical core for each virtual machine vCPU. These virtual machines offer 2 GiB of memory per vCPU and a wide range of vCPU sizes. These VMs meet the requirements of most non-memory-intensive and scale-out workloads such as microservices, small databases, caches, gaming servers, and more. Dplsv6-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines. For more information, [see pricing for disks](https://azure.microsoft.com/pricing/details/managed-disks/). Dplsv6-series virtual machines offer up to 96 vCPU and 192 GiB of RAM. These VMs come without local disk, providing a better value proposition for workloads that don't require local temporary storage.

[View the full Dplsv6-series page](dplsv6-series).

| Part | QuantityCount Units | SpecsSKU ID, Performance Units, etc. |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | Azure Cobalt 100 [Arm64] |
| Memory | 4 - 192 GiB |  |
| Local Storage | None |  |
| Remote Storage | 8 - 64 Disks | 4,000 - 200,000 IOPS 106 - 5,850 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 8 NICs | 12,500 - 60,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Dpdsv6 and Dpldsv6-series

# [Dpdsv6-series](#tab/dpdsv6)
The Dpdsv6-series virtual machines are powered by Azure's first-generation Cobalt 100 processor, delivering outstanding performance for general-purpose workloads. The Azure Cobalt 100 processor operates at 3.4 GHz and provides an entire physical core for each virtual machine vCPU. These virtual machines offer 4 GiB of memory per vCPU and a wide range of vCPU sizes. These VMs meet the requirements of most scale-out enterprise workloads such as web and application servers, small to medium databases, caches, and more. Dpdsv6-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines. For more information, [see pricing for disks](https://azure.microsoft.com/pricing/details/managed-disks/). Dpdsv6-series virtual machines offer up to 96 vCPU, up to 384 GiB of RAM, and up to 5,280 GiB of fast local NVMe temporary storage.

[View the full Dpdsv6-series page](dpdsv6-series).

| Part | QuantityCount Units | SpecsSKU ID, Performance Units, etc. |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | Azure Cobalt 100 [Arm64] |
| Memory | 8 - 384 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 880 GiB 15,000 - 1,800,000 IOPS  90 - 8,640 MBps |
| Remote Storage | 8 - 64 Disks | 4,000 - 200,000 IOPS 106 - 5,850 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 8 NICs | 12,500 - 60,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Dpldsv6-series](#tab/dpldsv6)
The Dpldsv6-series virtual machines are powered by Azure's first-generation Cobalt 100 processor, delivering outstanding performance for general-purpose workloads. The Azure Cobalt 100 processor operates at 3.4 GHz and provides an entire physical core for each virtual machine vCPU. These virtual machines offer 2 GiB of memory per vCPU and a wide range of vCPU sizes. These VMs meet the requirements of most non-memory-intensive and scale-out workloads such as microservices, small databases, caches, gaming servers, and more. Dpldsv6-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines. For more information, [see pricing for disks](https://azure.microsoft.com/pricing/details/managed-disks/). Dpldsv6-series virtual machines offer up to 96 vCPU, up to 192 GiB of RAM, and up to 5,280 GiB of fast local NVMe temporary storage.

[View the full Dpldsv6-series page](dpldsv6-series).

| Part | QuantityCount Units | SpecsSKU ID, Performance Units, etc. |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | Azure Cobalt 100 [Arm64] |
| Memory | 4 - 192 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 880 GiB 15,000 - 1,800,000 IOPS  90 - 8,640 MBps |
| Remote Storage | 8 - 64 Disks | 4,000 - 200,000 IOPS 106 - 5,850 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 8 NICs | 12,500 - 60,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Dasv6 and Dadsv6-series

# [Dasv6-series](#tab/dasv6)
Dasv6-series VMs utilize AMD's 4th Generation EPYC™ 9004 processors that can achieve a boosted maximum frequency of 3.7GHz. These virtual machines offer up to 96 vCPU and 384 GiB of RAM. The Dasv6-series sizes offer a combination of vCPU and memory for most production workloads. The new VMs with no local disk provide a better value proposition for workloads that do not require local temporary storage.

[View the full Dasv6-series page](dasv6-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | AMD EPYC 9004 (Genoa) [x86-64] |
| Memory | 8 - 384 GB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 4,000 - 175,000 IOPS 90 - 4,320 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2) |
| Network | 2 - 8 NICs | 12,500 - 40,000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

# [Dadsv6-series](#tab/dadsv6)
Dadsv6-series VMs utilize AMD's 4th Generation EPYC™ 9004 processors that can achieve a boosted maximum frequency of 3.7GHz. These virtual machines offer up to 96 vCPU and 384 GiB of RAM. The Dadsv6-series sizes offer a combination of vCPU, memory and fast local NVMe temporary storage for most production workloads. Dadsv6-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Dadsv6-series page](dadsv6-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | AMD EPYC 9004 (Genoa) [x86-64] |
| Memory | 8 - 384 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 880 GiB 38,000 - 1,800,000 IOPS 180 - 8,640 MBps |
| Remote Storage | 4 - 32 Disks | 4,000 - 175,000 IOPS 90 - 4,320 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2) |
| Network | 2 - 8 NICs | 12,500 - 40,000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

---

### Dalsv6 and Daldsv6-series

# [Dalsv6-series](#tab/dalsv6)
Dalsv6-series VMs utilize AMD's 4th Generation EPYC™ 9004 processors that can achieve a boosted maximum frequency of 3.7GHz. These virtual machines offer up to 96 vCPU and 192 GiB of RAM. These VM sizes can reduce cost when running non-memory intensive applications. The new VMs with no local disk provide a better value proposition for workloads that do not require local temporary storage.

[View the full Dalsv6-series page](dalsv6-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | AMD EPYC 9004 (Genoa) [x86-64] |
| Memory | 4 - 192 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 4,000 - 175,000 IOPS 90 - 4,320 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2) |
| Network | 2 - 8 NICs | 12,500 - 40,000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

# [Daldsv6-series](#tab/daldsv6)
Daldsv6-series VMs utilize AMD's 4th Generation EPYC™ 9004 processors that can achieve a boosted maximum frequency of 3.7GHz. These virtual machines offer up to 96 vCPUs, 192 GiB of RAM, and up to 5,280 GiB of fast local NVMe temporary storage. These VM sizes can reduce cost when running non-memory intensive applications. Daldsv6-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Daldsv6-series page](daldsv6-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | AMD EPYC 9004 (Genoa) [x86-64] |
| Memory | 4 - 192 GiB |  |
| Local Storage | 1 - 6 Disks | 110 - 880 GiB 38,000 - 1,800,000 IOPS 180 - 8,640 MBps |
| Remote Storage | 4 - 32 Disks | 4,000 - 175,000 IOPS 90 - 4,320 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2) |
| Network | 2 - 8 NICs | 12,500 - 40,000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

---

### Dv5 and Dsv5-series

# [Dv5-series](#tab/dv5)
The Dv5 and Dsv5-series virtual machines run on Intel® Xeon® Platinum 8473C (Sapphire Rapids), Intel® Xeon® Platinum 8370C (Ice Lake) processor in a [hyper threaded](https://www.intel.com/content/www/us/en/gaming/resources/hyper-threading.html) configuration, providing a better value proposition for most general-purpose workloads. This new processor features an all core turbo clock speed of 3.5 GHz with [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html) and [Intel® Deep Learning Boost](https://software.intel.com/content/www/us/en/develop/topics/ai/deep-learning-boost.html). These virtual machines offer a combination of vCPUs and memory to meet the requirements associated with most enterprise workloads, such as small-to-medium databases, low-to-medium traffic web servers, application servers and more. The Dv5 and Dsv5-series provide a better value proposition for workloads that don't require local temp disk. For information about similar virtual machines with local disk, see [Ddv5 and Ddsv5-series VMs](../../ddv5-ddsv5-series).

[View the full Dv5-series page](dv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | Intel Xeon Platinum 8473C (Sapphire Rapids) [x86-64] Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 8 - 384 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 4,000 - 80,000 IOPS 85 - 2,600 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds) |
| Network | 2 - 8 NICs | 12,500 - 35,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Dsv5-series](#tab/dsv5)
The Dv5 and Dsv5-series virtual machines run on Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8473C (Sapphire Rapids), Intel® Xeon® Platinum 8370C (Ice Lake) processor in a [hyper threaded](https://www.intel.com/content/www/us/en/gaming/resources/hyper-threading.html) configuration, providing a better value proposition for most general-purpose workloads. This new processor features an all core turbo clock speed of 3.5 GHz with [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html) and [Intel® Deep Learning Boost](https://software.intel.com/content/www/us/en/develop/topics/ai/deep-learning-boost.html). These virtual machines offer a combination of vCPUs and memory to meet the requirements associated with most enterprise workloads, such as small-to-medium databases, low-to-medium traffic web servers, application servers and more. The Dv5 and Dsv5-series provide a better value proposition for workloads that don't require local temp disk. For information about similar virtual machines with local disk, see [Ddv5 and Ddsv5-series VMs](../../ddv5-ddsv5-series).

[View the full Dsv5-series page](dsv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | Intel Xeon Platinum 8473C (Sapphire Rapids) [x86-64] Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 8 - 384 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 4,000 - 80,000 IOPS 85 - 2,600 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 8 NICs | 12,500 - 35,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Ddv5 and Ddsv5-series

# [Ddv5-series](#tab/ddv5)
The Ddv5 and Ddsv5-series Virtual Machines run on the Intel® Xeon® Platinum 8573C (Emerald Rapids) or the Intel® Xeon® Platinum 8370C (Ice Lake) processor in a [hyper threaded](https://www.intel.com/content/www/us/en/gaming/resources/hyper-threading.html) configuration, providing a better value proposition for most general-purpose workloads. This new processor features an all core turbo clock speed of 3.5 GHz with [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html) and [Intel® Deep Learning Boost](https://software.intel.com/content/www/us/en/develop/topics/ai/deep-learning-boost.html). These virtual machines offer a combination of vCPUs, memory and temporary storage able to meet the requirements associated with most enterprise workloads, such as small-to-medium databases, low-to-medium traffic web servers, application servers and more.

[View the full Ddv5-series page](ddv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 8 - 384 GiB |  |
| Local Storage | 1 Disk | 75 - 3,600 GiB 9,000 - 450,000 IOPS 125 - 4,000 MBps |
| Remote Storage | 4 - 32 Disks | 4,000 - 80,000 IOPS 85 - 2,600 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds) |
| Network | 2 - 8 NICs | 12,500 - 35,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Ddsv5-series](#tab/ddsv5)
The Ddv5 and Ddsv5-series Virtual Machines run on the Intel® Xeon® Platinum 8573C (Emerald Rapids) or the Intel® Xeon® Platinum 8370C (Ice Lake) processor in a [hyper threaded](https://www.intel.com/content/www/us/en/gaming/resources/hyper-threading.html) configuration, providing a better value proposition for most general-purpose workloads. This new processor features an all core turbo clock speed of 3.5 GHz with [Intel® Turbo Boost Technology](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Advanced-Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html) and [Intel® Deep Learning Boost](https://software.intel.com/content/www/us/en/develop/topics/ai/deep-learning-boost.html). These virtual machines offer a combination of vCPUs, memory and temporary storage able to meet the requirements associated with most enterprise workloads, such as small-to-medium databases, low-to-medium traffic web servers, application servers and more.

[View the full Ddsv5-series page](ddsv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 8 - 384 GiB |  |
| Local Storage | 1 Disk | 75 - 3,600 GiB 9,000 - 450,000 IOPS 125 - 4,000 MBps |
| Remote Storage | 4 - 32 Disks | 4,000 - 80,000 IOPS 85 - 2,600 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 8 NICs | 12,500 - 35,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Dasv5 and Dadsv5-series

# [Dasv5-series](#tab/dasv5)
Dasv5-series VMs utilize AMD's 3rd Generation EPYC™ 7763v and AMD's 4th Generation EPYC™ 9004 processors. The Dasv5-series sizes offer a combination of vCPU and memory for most production workloads. The new VMs with no local disk provide a better value proposition for workloads that do not require local temp disk.

[View the full Dasv5-series page](dasv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | AMD EPYC 7763v (Milan) [x86-64] AMD EPYC 9004 (Genoa) [x86-64] |
| Memory | 8 - 384 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 4,000 - 80,000 IOPS 82 - 1,600 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 8 NICs | 12,500 - 40,000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

# [Dadsv5-series](#tab/dadsv5)
Dadsv5-series utilize AMD's third Generation EPYC™ 7763v processors and AMD's 4th Generation EPYC™ 9004 processors. The Dadsv5-series sizes offer a combination of vCPU, memory, and temporary storage for most production workloads. The new VMs have 50% larger local storage and better local disk IOPS for both read and write compared to the Dav4/Dasv4 sizes with Gen2 VMs.

Dadsv5-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines.

[View the full Dadsv5-series page](dadsv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | AMD EPYC 7763v (Milan) [x86-64] , AMD EPYC 9004 (Genoa) [x86-64] |
| Memory | 8 - 384 GiB |  |
| Local Storage | 1 Disk | 75 - 3,600 GiB 9,000 - 450,000 IOPS 125 - 4,000 MBps |
| Remote Storage | 4 - 32 Disks | 4,000 - 80,000 IOPS 82 - 1,600 MBps Disk Types: [Premium SSD](../../disks-types#premium-ssds) |
| Network | 2 - 8 NICs | 12,500 - 40,000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

---

### Dpsv5 and Dpdsv5-series

# [Dpsv5-series](#tab/dpsv5)
The Dpsv5-series and Dpdsv5-series virtual machines are based on the Arm architecture, delivering outstanding price-performance for general-purpose workloads. These virtual machines feature the Ampere® Altra® Arm-based processor operating at 3.0 GHz, which provides an entire physical core for each virtual machine vCPU. These virtual machines offer a range of vCPU sizes, up to 4 GiB of memory per vCPU, and temporary storage options able to meet the requirements of scale-out and most enterprise workloads such as web and application servers, small to medium databases, caches, and more.

[View the full Dpsv5-series page](dpsv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 64 vCPUs | Ampere Altra [Arm64] |
| Memory | 8 - 208 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 4,000 - 80,000 IOPS 85 - 1,735 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds) |
| Network | 2 - 8 NICs | 12,500 - 40,000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

# [Dpdsv5-series](#tab/dpdsv5)
The Dpsv5-series and Dpdsv5-series virtual machines are based on the Arm architecture, delivering outstanding price-performance for general-purpose workloads. These virtual machines feature the Ampere® Altra® Arm-based processor operating at 3.0 GHz, which provides an entire physical core for each virtual machine vCPU. These virtual machines offer a range of vCPU sizes, up to 4 GiB of memory per vCPU, and temporary storage options able to meet the requirements of scale-out and most enterprise workloads such as web and application servers, small to medium databases, caches, and more.

[View the full Dpdsv5-series page](dpdsv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 64 vCPUs | Ampere Altra [Arm64] |
| Memory | 8 - 208 GiB |  |
| Local Storage | 1 Disk | 75 - 2,400 GiB 9,000 - 300,000 IOPS 125 - 4,000 MBps |
| Remote Storage | 4 - 32 Disks | 4,000 - 80,000 IOPS 85 - 1,735 MBps Disk Types: [Premium SSD](../../disks-types#premium-ssds) |
| Network | 2 - 8 NICs | 12,500 - 40,000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

---

### Dplsv5 and Dpldsv5-series

# [Dplsv5-series](#tab/dplsv5)
The Dplsv5-series and Dpldsv5-series virtual machines are based on the Arm architecture, delivering outstanding price-performance for general-purpose workloads. These virtual machines feature the Ampere® Altra® Arm-based processor operating at 3.0 GHz, which provides an entire physical core for each virtual machine vCPU. These virtual machines offer a range of vCPU sizes, up to 2 GiB of memory per vCPU, and temporary storage options able to meet the requirements of most non-memory-intensive and scale-out workloads such as microservices, small databases, caches, gaming servers, and more.

[View the full Dplsv5-series page](dplsv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 64 vCPUs | Ampere Altra [Arm64] |
| Memory | 4 - 128 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 4,000 - 80,000 IOPS 85 - 1,735 MBps Disk Types: [Premium SSD](../../disks-types#premium-ssds) |
| Network | 2 - 8 NICs | 12,500 - 40,000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

# [Dpldsv5-series](#tab/dpldsv5)
The Dplsv5-series and Dpldsv5-series virtual machines are based on the Arm architecture, delivering outstanding price-performance for general-purpose workloads. These virtual machines feature the Ampere® Altra® Arm-based processor operating at 3.0 GHz, which provides an entire physical core for each virtual machine vCPU. These virtual machines offer a range of vCPU sizes, up to 2 GiB of memory per vCPU, and temporary storage options able to meet the requirements of most non-memory-intensive and scale-out workloads such as microservices, small databases, caches, gaming servers, and more.

[View the full Dpldsv5-series page](dpldsv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 64 vCPUs | Ampere Altra [Arm64] |
| Memory | 4 - 128 GiB |  |
| Local Storage | 1 Disk | 75 - 2,400 GiB 9,000 - 300,000 IOPS 125 - 4,000 MBps |
| Remote Storage | 4 - 32 Disks | 4,000 - 80,000 IOPS 85 - 1,735 MBps Disk Types: [Premium SSD](../../disks-types#premium-ssds) |
| Network | 2 - 8 NICs | 12,500 - 40,000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

---

### Dlsv5 and Dldsv5-series

# [Dlsv5-series](#tab/dlsv5)
Dlsv5-series virtual machines run on Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8473C (Sapphire Rapids), or Intel® Xeon® Platinum 8370C (Ice Lake) processor reaching an all core turbo clock speed of up to 3.5 GHz. These virtual machines offer up to 96 vCPU and 192 GiB of RAM. These VM sizes can reduce cost when not running memory intensive applications.

Dlsv5-series virtual machines don't have any temporary storage thus lowering the price of entry. You can attach Standard SSD, Standard HDD, Premium SSD, and Premium SSD v2 disk storage to these virtual machines. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines. See pricing for disks.

[View the full Dlsv5-series page](dlsv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | Intel Xeon Platinum 8473C (Sapphire Rapids) [x86-64] Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 4 - 192 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 4,000 - 80,000 IOPS 85 - 4,000 MBps Disk Types: [Standard HDD/SSD](/en-us/azure/virtual-machines/disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 8 NICs | 12,500 - 35,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Dldsv5-series](#tab/dldsv5)
Dldsv5-series virtual machines run on the Intel® Xeon® Platinum 8573C (Emerald Rapids) or the Intel® Xeon® Platinum 8370C (Ice Lake) processor reaching an all core turbo clock speed of up to 3.5 GHz. These virtual machines offer up to 96 vCPU and 192 GiB of RAM and fast, local SSD storage up to 3,600 GiB. These VM sizes can reduce cost when not running memory intensive applications.

Dldsv5-series virtual machines support Standard SSD, Standard HDD, and Premium SSD types. You can also attach Ultra Disk storage based on its regional availability. Disk storage is billed separately from virtual machines. See pricing for disks.

[View the full Dldsv5-series page](dldsv5-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | Intel Xeon Platinum 8473C (Sapphire Rapids) [x86-64] Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 4 - 192 GiB |  |
| Local Storage | 1 Disk | 75 - 3,600 9,000 - 450,000 IOPS 125 - 4,000 MBps |
| Remote Storage | 4 - 32 Disks | 4,000 - 80,000 IOPS 85 - 4,000 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2) |
| Network | 2 - 8 NICs | 12,500 - 35,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Dv4 and Dsv4-series

# [Dv4-series](#tab/dv4)
The Dv4 and Dsv4-series run on Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8473C (Sapphire Rapids), Intel® Xeon® Platinum 8370C (Ice Lake), or Intel® Xeon® Platinum 8272CL (Cascade Lake) processors in a hyper-threaded configuration, providing a better value proposition for most general-purpose workloads. It features an all core Turbo clock speed of 3.4 GHz, [Intel® Turbo Boost Technology 2.0](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Hyper-Threading Technology](https://www.intel.com/content/www/us/en/gaming/resources/hyper-threading.html) and [Intel® Advanced Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html). They also support [Intel® Deep Learning Boost](https://software.intel.com/content/www/us/en/develop/topics/ai/deep-learning-boost.html).

[View the full Dv4-series page](dv4-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 64 vCPUs | Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8272CL (Cascade Lake) [x86-64] Intel Xeon Platinum 8473C (Sapphire Rapids) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 8 - 256 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 3,000 - 80,000 IOPS 48 - 1,200 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds) |
| Network | 2 - 8 NICs | 5,000 - 30,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Dsv4-series](#tab/dsv4)
The Dv4 and Dsv4-series run on Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8473C (Sapphire Rapids), Intel® Xeon® Platinum 8370C (Ice Lake), or Intel® Xeon® Platinum 8272CL (Cascade Lake) processors in a hyper-threaded configuration, providing a better value proposition for most general-purpose workloads. It features an all core Turbo clock speed of 3.4 GHz, [Intel® Turbo Boost Technology 2.0](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Hyper-Threading Technology](https://www.intel.com/content/www/us/en/gaming/resources/hyper-threading.html) and [Intel® Advanced Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html). They also support [Intel® Deep Learning Boost](https://software.intel.com/content/www/us/en/develop/topics/ai/deep-learning-boost.html).

[View the full Dsv4-series page](dsv4-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 64 vCPUs | Intel Xeon Platinum 8473C (Sapphire Rapids) [x86-64] Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8272CL (Cascade Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 8 - 256 GiB |  |
| Local Storage | None |  |
| Remote Storage | 4 - 32 Disks | 3,000 - 80,000 IOPS 48 - 1,200 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 8 NICs | 5,000 - 30,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Dav4 and Dasv4-series

# [Dav4-series](#tab/dav4)
The Dav4-series run on 2nd Generation AMD EPYC™ 7452 (up to 3.35GHz) or 3rd Generation EPYC™ 7763v processors (up to 3.5GHz). The Dav4-series sizes offer a combination of vCPU, memory and temporary storage for most production workloads. Data disk storage is billed separately from virtual machines. To use Premium SSD, use the Dasv4 sizes. The pricing and billing meters for Dasv4 sizes are the same as the Dav4-series.

[View the full Dav4-series page](dav4-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | AMD EPYC 7452 (Rome) [x86-64] AMD EPYC 7763v (Milan) [x86-64] |
| Memory | 8 - 384 GiB |  |
| Local Storage | 1 Disk | 50 - 2,400 GiB 3,000 - 96,000 IOPS 46 - 1,000 MBps |
| Remote Storage | 4 - 32 Disks | 3,000 - 80,000 IOPS 48 - 1,200 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 8 NICs | 2,000 - 40,000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

# [Dasv4-series](#tab/dasv4)
The Dasv4-series run on 2nd Generation AMD EPYC™ 7452 (up to 3.35GHz) or 3rd Generation EPYC™ 7763v processors (up to 3.5GHz) and use Premium SSD. The Dasv4-series sizes offer a combination of vCPU, memory and temporary storage for most production workloads.

[View the full Dasv4-series page](dasv4-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 96 vCPUs | AMD EPYC 7452 (Rome) [x86-64] AMD EPYC 7763v (Genoa) [x86-64] |
| Memory | 8 - 384 GiB |  |
| Local Storage | 4 - 32 Disks | 16 - 768 GiB 4,000 - 192,000 IOPS 32 - 1,020 MBps |
| Remote Storage | 4 - 32 Disks | 3,000 - 80,000 IOPS 48 - 1,200 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 8 NICs | 2,000 - 40,000 Mbps Interfaces: NetVSC, ConnectX |
| Accelerators | None |  |

---

### Ddv4 and Ddsv4-series

# [Ddv4-series](#tab/ddv4)
The Ddv4 and Ddsv4-series run on the Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8370C (Ice Lake) or the Intel® Xeon® Platinum 8272CL (Cascade Lake) processors in a hyper-threaded configuration, providing a better value proposition for most general-purpose workloads. It features an all core Turbo clock speed of 3.4 GHz, [Intel® Turbo Boost Technology 2.0](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Hyper-Threading Technology](https://www.intel.com/content/www/us/en/gaming/resources/hyper-threading.html) and [Intel® Advanced Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html). They also support [Intel® Deep Learning Boost](https://software.intel.com/content/www/us/en/develop/topics/ai/deep-learning-boost.html). These new VM sizes will have 50% larger local storage, as well as better local disk IOPS for both read and write compared to the [Dv3/Dsv3](../../dv3-dsv3-series) sizes with [Gen2 VMs](../../generation-2). D-series use cases include enterprise-grade applications, relational databases, in-memory caching, and analytics.

[View the full Ddv4-series page](ddv4-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 64 vCPUs | Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8272CL (Cascade Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 8 - 256 GiB |  |
| Local Storage | 1 Disk | 75 - 2,400 GiB 9,000 - 300,000 IOPS 125 - 4,000 MBps |
| Remote Storage | 4 - 32 Disks | 3,000 - 80,000 IOPS 48 - 1,200 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds) |
| Network | 2 - 8 NICs | 5,000 - 30,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Ddsv4-series](#tab/ddsv4)
The Ddv4 and Ddsv4-series run on the Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8370C (Ice Lake) or the Intel® Xeon® Platinum 8272CL (Cascade Lake) processors in a hyper-threaded configuration, providing a better value proposition for most general-purpose workloads. It features an all core Turbo clock speed of 3.4 GHz, [Intel® Turbo Boost Technology 2.0](https://www.intel.com/content/www/us/en/architecture-and-technology/turbo-boost/turbo-boost-technology.html), [Intel® Hyper-Threading Technology](https://www.intel.com/content/www/us/en/gaming/resources/hyper-threading.html) and [Intel® Advanced Vector Extensions 512 (Intel® AVX-512)](https://www.intel.com/content/www/us/en/architecture-and-technology/avx-512-overview.html). They also support [Intel® Deep Learning Boost](https://software.intel.com/content/www/us/en/develop/topics/ai/deep-learning-boost.html). These new VM sizes will have 50% larger local storage, as well as better local disk IOPS for both read and write compared to the [Dv3/Dsv3](../../dv3-dsv3-series) sizes with [Gen2 VMs](../../generation-2). D-series use cases include enterprise-grade applications, relational databases, in-memory caching, and analytics.

[View the full Ddsv4-series page](ddsv4-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 64 vCPUs | Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8272CL (Cascade Lake) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 8 - 256 GiB |  |
| Local Storage | 1 Disk | 75 - 2,400 GiB 9,000 - 300,000 IOPS 125 - 4,000 MBps |
| Remote Storage | 4 - 32 Disks | 3,000 - 80,000 IOPS 48 - 1,200 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 8 NICs | 5,000 - 30,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Dv3 and Dsv3-series

Warning

The Dv3 and Dsv3 series are in the [End of Life](../lifecycle/lifecycle-overview#end-of-life) lifecycle stage and retire on **November 15, 2029**. After that date, you can't create, resize into, run, or purchase any of the 14 Dv3-series and Dsv3-series sizes. For the smoothest transition, see [Modernize to the v5 VM series](../lifecycle/sizes-v5-modernization-overview). For the latest features and performance, see [Modernize to the v6 and v7 VM series](../lifecycle/sizes-v6-v7-modernization-overview). For retirement details, see [Retired and retiring VM size series](../lifecycle/retirements-and-capacity-restrictions#general-purpose-retired-sizes).

# [Dv3-series](#tab/dv3)
The Dv3-series run on the Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8370C (Ice Lake), Intel® Xeon® Platinum 8272CL (Cascade Lake), Intel® Xeon® 8171M 2.1GHz (Skylake), Intel® Xeon® E5-2673 v4 2.3 GHz (Broadwell), or the Intel® Xeon® E5-2673 v3 2.4 GHz (Haswell) processors in a hyper-threaded configuration, providing a better value proposition for most general purpose workloads. Memory has been expanded (from ~3.5 GiB/vCPU to 4 GiB/vCPU) while disk and network limits have been adjusted on a per core basis to align with the move to hyperthreading. The Dv3-series no longer has the high memory VM sizes of the D/Dv2-series, those have been moved to the memory optimized Ev3 and Esv3-series. Example D-series use cases include enterprise-grade applications, relational databases, in-memory caching, and analytics.

[View the full Dv3-series page](dv3-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 64 vCPUs | Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8272CL (Cascade Lake) [x86-64] Intel Xeon 8171M (Skylake) [x86-64] Intel Xeon E5-2673 v4 (Broadwell) [x86-64] Intel Xeon E5-2673 v3 (Haswell) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 8 - 256 GiB |  |
| Local Storage | 1 Disk | 50 - 1,600 GiB 3,000 - 96,000 IOPS 46 - 1,000 MBps |
| Remote Storage | 4 - 32 Disks | Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds) |
| Network | 2 - 8 NICs | 1,000 - 30,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Dsv3-series](#tab/dsv3)
The Dv3-series run on the Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8370C (Ice Lake), Intel® Xeon® Platinum 8272CL (Cascade Lake), Intel® Xeon® 8171M 2.1GHz (Skylake), Intel® Xeon® E5-2673 v4 2.3 GHz (Broadwell), or the Intel® Xeon® E5-2673 v3 2.4 GHz (Haswell) processors in a hyper-threaded configuration, providing a better value proposition for most general purpose workloads. Memory has been expanded (from ~3.5 GiB/vCPU to 4 GiB/vCPU) while disk and network limits have been adjusted on a per core basis to align with the move to hyperthreading. The Dv3-series no longer has the high memory VM sizes of the D/Dv2-series, those have been moved to the memory optimized Ev3 and Esv3-series. Example D-series use cases include enterprise-grade applications, relational databases, in-memory caching, and analytics.

[View the full Dsv3-series page](dsv3-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 2 - 64 vCPUs | Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8272CL (Cascade Lake) [x86-64] Intel Xeon 8171M (Skylake) [x86-64] Intel Xeon E5-2673 v4 (Broadwell) [x86-64] Intel Xeon E5-2673 v3 (Haswell) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 8 - 256 GiB |  |
| Local Storage | 1 Disks | 16 - 512 GiB 4,000 - 128,000 IOPS 32 - 1,024 MBps |
| Remote Storage | 4 - 32 Disks | 4,000 - 80,000 IOPS 48 - 1,200 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds), [Premium SSD](../../disks-types#premium-ssds), [Premium SSD v2](../../disks-types#premium-ssd-v2), [Ultra Disk](../../disks-types#ultra-disks) |
| Network | 2 - 8 NICs | 1,000 - 30,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### Dv2 and Dsv2-series

# [Dv2-series](#tab/dv2)
The Dv2 and DSv2-series, a follow-on to the original D-series, feature a more powerful CPU and optimal CPU-to-memory configuration making them suitable for most production workloads. The Dv2-series is about 35% faster than the D-series. Dv2-series run on the Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8370C (Ice Lake), Intel® Xeon® Platinum 8272CL (Cascade Lake), Intel® Xeon® 8171M 2.1GHz (Skylake), Intel® Xeon® E5-2673 v4 2.3 GHz (Broadwell), or the Intel® Xeon® E5-2673 v3 2.4 GHz (Haswell) processors with the Intel Turbo Boost Technology 2.0. The Dv2-series has the same memory and disk configurations as the D-series.

[View the full Dv2-series page](dv2-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 1 - 16 vCPUs | Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8272CL (Cascade Lake) [x86-64] Intel Xeon 8171M (Skylake) [x86-64] Intel Xeon E5-2673 v4 (Broadwell) [x86-64] Intel Xeon E5-2673 v3 (Haswell) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 3.5 - 56 GiB |  |
| Local Storage | 1 Disk | 50 - 800 GiB 3,000 - 48,000 IOPS 46 - 750 MBps |
| Remote Storage | 4 - 64 Disks | 4x500 - 64x500 IOPS Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds) |
| Network | 2 - NICs | 750 - 12,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

# [Dsv2-series](#tab/dsv2)
The Dv2 and DSv2-series, a follow-on to the original D-series, feature a more powerful CPU and optimal CPU-to-memory configuration making them suitable for most production workloads. The Dv2-series is about 35% faster than the D-series. Dv2-series run on the Intel® Xeon® Platinum 8573C (Emerald Rapids), Intel® Xeon® Platinum 8370C (Ice Lake), Intel® Xeon® Platinum 8272CL (Cascade Lake), Intel® Xeon® 8171M 2.1GHz (Skylake), Intel® Xeon® E5-2673 v4 2.3 GHz (Broadwell), or the Intel® Xeon® E5-2673 v3 2.4 GHz (Haswell) processors with the Intel Turbo Boost Technology 2.0. The Dv2-series has the same memory and disk configurations as the D-series.

[View the full Dsv2-series page](dsv2-series).

| Part | Quantity^Count Units^ | Specs^SKU ID, Performance Units, etc.^ |
| --- | --- | --- |
| Processor | 1 - 16 vCPUs | Intel Xeon Platinum 8370C (Ice Lake) [x86-64] Intel Xeon Platinum 8272CL (Cascade Lake) [x86-64] Intel Xeon 8171M (Skylake) [x86-64] Intel Xeon E5-2673 v4 (Broadwell) [x86-64] Intel Xeon E5-2673 v3 (Haswell) [x86-64] Intel Xeon Platinum 8573C (Emerald Rapids) [x86-64] |
| Memory | 3.5 - 56 GiB |  |
| Local Storage | 1 Disk | 7 - 112 GiB 4,000 - 64,000 IOPS 32 - 512 MBps |
| Remote Storage | 4 - 64 Disks | 3,000 - 51,000 IOPS 48 - 768 MBps Disk Types: [Standard SDD/HDD](../../disks-types#standard-ssds) |
| Network | 2 - 8 NICs | 750 - 12,000 Mbps Interfaces: NetVSC, ConnectX, [MANA](https://aka.ms/ManaFAQ1) |
| Accelerators | None |  |

---

### End of Life D family series

For End of Life sizes, see [End of Life sizes](../lifecycle/end-of-life-sizes-list#general-purpose-end-of-life-sizes).

## Other size information

List of all available sizes: [Sizes](../../sizes)

Pricing Calculator: [Pricing Calculator](https://azure.microsoft.com/pricing/calculator/)

Information on Disk Types: [Disk Types](../../disks-types)
