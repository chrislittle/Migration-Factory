# Azure VM sizes naming conventions - Azure Virtual Machines | Microsoft Learn

**Applies to:** ✔️ Linux VMs ✔️ Windows VMs ✔️ Flexible scale sets ✔️ Uniform scale sets

This page outlines the naming conventions used for Azure VMs. VMs use these naming conventions to denote varying features and specifications.

## Naming convention explanation

**[Family]** + *[Sub-family]*\* + **[# of vCPUs]** + *[Constrained vCPUs]*\* + **[Additive Features]** + *[Accelerator Type]*\* + *[Memory Capacity]*\* + **[Version]**

| Value | Explanation |
| --- | --- |
| Family | Indicates the VM Family Series. For more information, see the [list of VM size families by type](sizes/overview#list-of-vm-size-families-by-type). |
| \*Subfamily | Used for specialized VM differentiations such as:  B = memory bandwidth optimized C = confidential (for DC, EC, NCC series)C = compute intensive (for HC, NC, NCC series) D = AI training and inference optimized G = cloud gaming and remote desktop optimized H = High core density V = visualization and graphics optimized X = extra memory |
| # of vCPUs | Denotes the number of vCPUs of the VM |
| \*Constrained vCPUs | Used for certain VM sizes only. Denotes the number of vCPUs for the [constrained vCPU capable size](constrained-vcpu) |
| Additive Features | Lower case letters denote additive features, such as: a = AMD-based processor b = remote storage bandwidth optimized d = includes [local temporary disks](overview#local-temporary-storage)e = encrypted; contains confidential TDX capabilities f = flat ratio (1:1) of vCPU to memory size i = isolated size l = low memory; decreased vCPU to memory ratio m = memory intensive; highest vCPU to memory ratio in a particular series n = network optimized; increased vCPU to network bandwidth ratio o = increased vCPU to local SSD storage capacity ratiop = ARM-based processor r = includes RDMA (InfiniBand) secondary network s = compatible with any Premium SSD type t = tiny memory; smallest vCPU to memory ratio in a particular size |
| \*Accelerator Type | Denotes the type of hardware accelerator in the specialized/GPU SKUs. Only new specialized/GPU SKUs launched from Q3 2020 have the hardware accelerator in the name. |
| \*Memory Capacity | Denotes M-series memory capacity, rounded to the nearest TiB. |
| Version | Denotes the version number of the VM Family Series |

## Example breakdown

**[Family]** + *[Sub-family]*\* + **[# of vCPUs]** + *[Constrained vCPUs]*\* + **[Additive Features]** + *[Accelerator Type]*\* + *[Memory Capacity]*\* + **[Version]**

### Example 1: M48ds\_1\_v3

| Value | Explanation |
| --- | --- |
| Family | M |
| # of vCPUs | 48 |
| Additive Features | d = local temp disk  s = Premium Storage capable |
| Memory Capacity | 974 GiB ≈ 1 TiB |
| Version | v3 |

### Example 2: NV16as\_v4

| Value | Explanation |
| --- | --- |
| Family | N |
| Subfamily | V |
| # of vCPUs | 16 |
| Additive Features | a = AMD-based processor  s = Premium Storage capable |
| Version | v4 |

### Example 3: NC4as\_T4\_v3

| Value | Explanation |
| --- | --- |
| Family | N |
| Subfamily | C |
| # of vCPUs | 4 |
| Additive Features | a = AMD-based processor  s = Premium Storage capable |
| Accelerator Type | T4 |
| Version | v3 |

### Example 4: M8-2ms\_v2 (Constrained vCPU)

| Value | Explanation |
| --- | --- |
| Family | M |
| # of vCPUs | 8 |
| Constrained vCPUs | 2 |
| Additive Features | m = memory intensive  s = Premium Storage capable |
| Version | v2 |

### Example 5: E96bds\_v5 (a SQL Server preferred option)

| Value | Explanation |
| --- | --- |
| Family | Eb |
| # of vCPUs | 96 |
| Additive Features | b = memory  d = includes [local temporary disks](overview#local-temporary-storage) s = Premium Storage capable |
| Version | v5 |
