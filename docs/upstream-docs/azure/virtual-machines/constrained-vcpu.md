# Constrained vCPU sizes - Azure Virtual Machines | Microsoft Learn

**Applies to:** ✔️ Linux VMs ✔️ Windows VMs ✔️ Flexible scale sets ✔️ Uniform scale sets

Tip

Try the **[Virtual Machine selector tool](https://aka.ms/vm-selector)** to find other sizes that best fit your workload.

Some database workloads require high memory, storage, and I/O bandwidth, but don't benefit from a high number of cores. Products designed for these workloads are often licensed on a per-CPU-core basis. This licensing system means that a VM size with otherwise ideal specifications but an excessive vCPU count can cause a substantial increase in licensing costs. To help manage your costs, Azure offers predefined VM sizes with a lowered vCPU count to help to reduce the cost of software licensing, while maintaining the same memory, storage, and I/O bandwidth.

The original size's available vCPU count can be reduced to either one half or one quarter of the original size specification. These new VM sizes have a suffix that specifies the number of available vCPUs to make them easier for you to identify. Learn more about [VM size naming conventions](vm-naming-conventions).

## Example workload

The licensing fees charged for SQL Server are based on the available vCPU count. Third party products should count the available vCPUs and report it as the amount to be used and licensed. This constraint results in a 50% to 75% increase in the ratio of the VM specs to available (billable) vCPUs while maintaining the benefits of the original VM size's specifications.

## Specification comparison

The Standard\_E32s\_v5 VM size comes with 32 vCPUs, 256 GiB of RAM, 32 disks, and 80,000 IOPs of I/O bandwidth. The pre-defined Standard\_E32-16s\_v5 and Standard\_E32-8s\_v5 VM sizes comes with 16 and 8 active vCPUs respectively, while maintaining the memory, storage, and I/O bandwidth specifications of the Standard\_E32s\_v5.

| Size type | Size name | Disabled vCPUs | Active vCPUs | Memory, Storage, I/O |
| --- | --- | --- | --- | --- |
| Base (Original) | Standard\_E32s\_v5 | 0 | **32** | 256 GiB, 32 Disks, 80,000 IOPs |
| Constrained | Standard\_E32-**16**s\_v5 | 16 | **16** | 256 GiB, 32 Disks, 80,000 IOPs |
| Constrained | Standard\_E32-**8**s\_v5 | 24 | **8** | 256 GiB, 32 Disks, 80,000 IOPs |

Note

Disabled vCPUs are not available for use by the VM. If your VM has multiple workloads assigned to it then it may require more vCPUs. If possible, relocate secondary tasks to another virtual machine to avoid increased licensing costs.

## Pricing

At this time, the VM pricing, remains the same as the original size. For more information, see [Azure VM sizes for more cost-effective database workloads](https://azure.microsoft.com/blog/announcing-new-azure-vm-sizes-for-more-cost-effective-database-workloads/).

## List of available sizes with constrained vCPUs

# [M-family sizes](#tab/family-M)
| Size name | Active vCPUs | Base size |
| --- | --- | --- |
| Standard\_M8-2ms | 2 | M8ms |
| Standard\_M8-4ms | 4 | M8ms |
| Standard\_M16-4ms | 4 | M16ms |
| Standard\_M16-8ms | 8 | M16ms |
| Standard\_M32-8ms | 8 | M32ms |
| Standard\_M32-16ms | 16 | M32ms |
| Standard\_M64-32ms | 32 | M64ms |
| Standard\_M64-16ms | 16 | M64ms |
| Standard\_M128-64ms | 64 | M128ms |
| Standard\_M128-32ms | 32 | M128ms |
| Standard\_M416-208s\_v2 | 208 | M416s\_v2 |
| Standard\_M416-208ms\_v2 | 208 | M416ms\_v2 |
| Standard\_M64-32bds\_1\_v3 | 32 | M64bds\_1\_v3 |
| Standard\_M96-48bds\_2\_v3 | 48 | M96bds\_2\_v3 |
| Standard\_M128-64bds\_3\_v3 | 64 | M128bds\_3\_v3 |
| Standard\_M176-88bds\_4\_v3 | 88 | M176bds\_4\_v3 |
| Standard\_M128-64bds\_v3 | 64 | M128bds\_v3 |
| Standard\_M176-88bds\_v3 | 88 | M176bds\_v3 |
| Standard\_M128-64bs\_v3 | 64 | M128bs\_v3 |
| Standard\_M176-88bs\_v3 | 88 | M176bs\_v3 |

# [E-family sizes](#tab/family-E)
| Size name | Active vCPUs | Base size |
| --- | --- | --- |
| Standard\_E4-2s\_v3 | 2 | E4s\_v3 |
| Standard\_E8-4s\_v3 | 4 | E8s\_v3 |
| Standard\_E8-2s\_v3 | 2 | E8s\_v3 |
| Standard\_E16-8s\_v3 | 8 | E16s\_v3 |
| Standard\_E16-4s\_v3 | 4 | E16s\_v3 |
| Standard\_E32-16s\_v3 | 16 | E32s\_v3 |
| Standard\_E32-8s\_v3 | 8 | E32s\_v3 |
| Standard\_E64-32s\_v3 | 32 | E64s\_v3 |
| Standard\_E64-16s\_v3 | 16 | E64s\_v3 |
| Standard\_E4-2s\_v4 | 2 | E4s\_v4 |
| Standard\_E8-4s\_v4 | 4 | E8s\_v4 |
| Standard\_E8-2s\_v4 | 2 | E8s\_v4 |
| Standard\_E16-8s\_v4 | 8 | E16s\_v4 |
| Standard\_E16-4s\_v4 | 4 | E16s\_v4 |
| Standard\_E32-16s\_v4 | 16 | E32s\_v4 |
| Standard\_E32-8s\_v4 | 8 | E32s\_v4 |
| Standard\_E64-32s\_v4 | 32 | E64s\_v4 |
| Standard\_E64-16s\_v4 | 16 | E64s\_v4 |
| Standard\_E4-2ds\_v4 | 2 | E4ds\_v4 |
| Standard\_E8-4ds\_v4 | 4 | E8ds\_v4 |
| Standard\_E8-2ds\_v4 | 2 | E8ds\_v4 |
| Standard\_E16-8ds\_v4 | 8 | E16ds\_v4 |
| Standard\_E16-4ds\_v4 | 4 | E16ds\_v4 |
| Standard\_E32-16ds\_v4 | 16 | E32ds\_v4 |
| Standard\_E32-8ds\_v4 | 8 | E32ds\_v4 |
| Standard\_E64-32ds\_v4 | 32 | E64ds\_v4 |
| Standard\_E64-16ds\_v4 | 16 | E64ds\_v4 |
| Standard\_E4-2s\_v5 | 2 | E4s\_v5 |
| Standard\_E8-4s\_v5 | 4 | E8s\_v5 |
| Standard\_E8-2s\_v5 | 2 | E8s\_v5 |
| Standard\_E16-8s\_v5 | 8 | E16s\_v5 |
| Standard\_E16-4s\_v5 | 4 | E16s\_v5 |
| Standard\_E32-16s\_v5 | 16 | E32s\_v5 |
| Standard\_E32-8s\_v5 | 8 | E32s\_v5 |
| Standard\_E64-32s\_v5 | 32 | E64s\_v5 |
| Standard\_E64-16s\_v5 | 16 | E64s\_v5 |
| Standard\_E96-48s\_v5 | 48 | E96s\_v5 |
| Standard\_E96-24s\_v5 | 24 | E96s\_v5 |
| Standard\_E4-2ds\_v5 | 2 | E4ds\_v5 |
| Standard\_E8-4ds\_v5 | 4 | E8ds\_v5 |
| Standard\_E8-2ds\_v5 | 2 | E8ds\_v5 |
| Standard\_E16-8ds\_v5 | 8 | E16ds\_v5 |
| Standard\_E16-4ds\_v5 | 4 | E16ds\_v5 |
| Standard\_E32-16ds\_v5 | 16 | E32ds\_v5 |
| Standard\_E32-8ds\_v5 | 8 | E32ds\_v5 |
| Standard\_E64-32ds\_v5 | 32 | E64ds\_v5 |
| Standard\_E64-16ds\_v5 | 16 | E64ds\_v5 |
| Standard\_E96-48ds\_v5 | 48 | E96ds\_v5 |
| Standard\_E96-24ds\_v5 | 24 | E96ds\_v5 |
| Standard\_E4-2as\_v4 | 2 | E4as\_v4 |
| Standard\_E8-4as\_v4 | 4 | E8as\_v4 |
| Standard\_E8-2as\_v4 | 2 | E8as\_v4 |
| Standard\_E16-8as\_v4 | 8 | E16as\_v4 |
| Standard\_E16-4as\_v4 | 4 | E16as\_v4 |
| Standard\_E32-16as\_v4 | 16 | E32as\_v4 |
| Standard\_E32-8as\_v4 | 8 | E32as\_v4 |
| Standard\_E64-32as\_v4 | 32 | E64as\_v4 |
| Standard\_E64-16as\_v4 | 16 | E64as\_v4 |
| Standard\_E96-48as\_v4 | 48 | E96as\_v4 |
| Standard\_E96-24as\_v4 | 24 | E96as\_v4 |
| Standard\_E4-2ads\_v5 | 2 | E4ads\_v5 |
| Standard\_E8-4ads\_v5 | 4 | E8ads\_v5 |
| Standard\_E8-2ads\_v5 | 2 | E8ads\_v5 |
| Standard\_E16-8ads\_v5 | 8 | E16ads\_v5 |
| Standard\_E16-4ads\_v5 | 4 | E16ads\_v5 |
| Standard\_E32-16ads\_v5 | 16 | E32ads\_v5 |
| Standard\_E32-8ads\_v5 | 8 | E32ads\_v5 |
| Standard\_E64-32ads\_v5 | 32 | E64ads\_v5 |
| Standard\_E64-16ads\_v5 | 16 | E64ads\_v5 |
| Standard\_E96-48ads\_v5 | 48 | E96ads\_v5 |
| Standard\_E96-24ads\_v5 | 24 | E96ads\_v5 |
| Standard\_E4-2as\_v5 | 2 | E4as\_v5 |
| Standard\_E8-4as\_v5 | 4 | E8as\_v5 |
| Standard\_E8-2as\_v5 | 2 | E8as\_v5 |
| Standard\_E16-8as\_v5 | 8 | E16as\_v5 |
| Standard\_E16-4as\_v5 | 4 | E16as\_v5 |
| Standard\_E32-16as\_v5 | 16 | E32as\_v5 |
| Standard\_E32-8as\_v5 | 8 | E32as\_v5 |
| Standard\_E64-32as\_v5 | 32 | E64as\_v5 |
| Standard\_E64-16as\_v5 | 16 | E64as\_v5 |
| Standard\_E96-48as\_v5 | 48 | E96as\_v5 |
| Standard\_E96-24as\_v5 | 24 | E96as\_v5 |
| Standard\_E4-2s\_v6 | 4 | E4s\_v6 |
| Standard\_E8-2s\_v6 | 8 | E8s\_v6 |
| Standard\_E8-4s\_v6 | 8 | E8s\_v6 |
| Standard\_E16-4s\_v6 | 16 | E16s\_v6 |
| Standard\_E16-8s\_v6 | 16 | E16s\_v6 |
| Standard\_E32-8s\_v6 | 32 | E32s\_v6 |
| Standard\_E32-16s\_v6 | 32 | E32s\_v6 |
| Standard\_E64-16s\_v6 | 64 | E64s\_v6 |
| Standard\_E64-32s\_v6 | 64 | E64s\_v6 |
| Standard\_E96-24s\_v6 | 96 | E96s\_v6 |
| Standard\_E96-48s\_v6 | 96 | E96s\_v6 |
| Standard\_E128-32s\_v6 | 128 | E128s\_v6 |
| Standard\_E128-64s\_v6 | 128 | E128s\_v6 |
| Standard\_E4-2ds\_v6 4 | 4 | E4ds\_v6 |
| Standard\_E8-2ds\_v6 | 8 | E8ds\_v6 |
| Standard\_E8-4ds\_v6 | 8 | E8ds\_v6 |
| Standard\_E16-4ds\_v6 | 16 | E16ds\_v6 |
| Standard\_E16-8ds\_v6 | 16 | E16ds\_v6 |
| Standard\_E32-8ds\_v6 | 32 | E32ds\_v6 |
| Standard\_E32-16ds\_v6 | 32 | E32ds\_v6 |
| Standard\_E64-16ds\_v6 | 16 | E64ds\_v6 |
| Standard\_E64-32ds\_v6 | 64 | E64ds\_v6 |
| Standard\_E96-24ds\_v6 | 96 | E96ds\_v6 |
| Standard\_E96-48ds\_v6 | 96 | E96ds\_v6 |
| Standard\_E128-32ds\_v6 | 128 | E128ds\_v6 |
| Standard\_E128-64ds\_v6 | 128 | E128ds\_v6 |
| Standard\_E4-2ads\_v7 | 2 | E4ads\_v7 |
| Standard\_E8-2ads\_v7 | 2 | E8ads\_v7 |
| Standard\_E8-4ads\_v7 | 4 | E8ads\_v7 |
| Standard\_E16-4ads\_v7 | 4 | E16ads\_v7 |
| Standard\_E16-8ads\_v7 | 8 | E16ads\_v7 |
| Standard\_E32-8ads\_v7 | 8 | E32ads\_v7 |
| Standard\_E32-16ads\_v7 | 16 | E32ads\_v7 |
| Standard\_E64-16ads\_v7 | 16 | E64ads\_v7 |
| Standard\_E64-32ads\_v7 | 32 | E64ads\_v7 |
| Standard\_E96-24ads\_v7 | 24 | E96ads\_v7 |
| Standard\_E96-48ads\_v7 | 48 | E96ads\_v7 |
| Standard\_E128-32ads\_v7 | 32 | E128ads\_v7 |
| Standard\_E128-64ads\_v7 | 64 | E128ads\_v7 |
| Standard\_E4-2as\_v7 | 2 | E4as\_v7 |
| Standard\_E8-2as\_v7 | 2 | E8as\_v7 |
| Standard\_E8-4as\_v7 | 4 | E8as\_v7 |
| Standard\_E16-4as\_v7 | 4 | E16as\_v7 |
| Standard\_E16-8as\_v7 | 8 | E16as\_v7 |
| Standard\_E32-8as\_v7 | 8 | E32as\_v7 |
| Standard\_E32-16as\_v7 | 16 | E32as\_v7 |
| Standard\_E64-16as\_v7 | 16 | E64as\_v7 |
| Standard\_E64-32as\_v7 | 32 | E64as\_v7 |
| Standard\_E96-24as\_v7 | 24 | E96as\_v7 |
| Standard\_E96-48as\_v7 | 48 | E96as\_v7 |
| Standard\_E128-32as\_v7 | 32 | E128as\_v7 |
| Standard\_E128-64as\_v7 | 64 | E128as\_v7 |

# [F-family sizes](#tab/family-F)
| Size name | Active vCPUs | Base size |
| --- | --- | --- |
| Standard\_F2-1amds\_v7 | 1 | F2amds\_v7 |
| Standard\_F4-1amds\_v7 | 1 | F4amds\_v7 |
| Standard\_F4-2amds\_v7 | 2 | F4amds\_v7 |
| Standard\_F8-2amds\_v7 | 2 | F8amds\_v7 |
| Standard\_F8-4amds\_v7 | 4 | F8amds\_v7 |
| Standard\_F16-4amds\_v7 | 4 | F16amds\_v7 |
| Standard\_F16-8amds\_v7 | 8 | F16amds\_v7 |
| Standard\_F32-8amds\_v7 | 8 | F32amds\_v7 |
| Standard\_F32-16amds\_v7 | 16 | F32amds\_v7 |
| Standard\_F64-16amds\_v7 | 16 | F64amds\_v7 |
| Standard\_F64-32amds\_v7 | 32 | F64amds\_v7 |
| Standard\_F2-1ams\_v7 | 1 | F2ams\_v7 |
| Standard\_F4-1ams\_v7 | 1 | F4ams\_v7 |
| Standard\_F4-2ams\_v7 | 2 | F4ams\_v7 |
| Standard\_F8-2ams\_v7 | 2 | F8ams\_v7 |
| Standard\_F8-4ams\_v7 | 4 | F8ams\_v7 |
| Standard\_F16-4ams\_v7 | 4 | F16ams\_v7 |
| Standard\_F16-8ams\_v7 | 8 | F16ams\_v7 |
| Standard\_F32-8ams\_v7 | 8 | F32ams\_v7 |
| Standard\_F32-16ams\_v7 | 16 | F32ams\_v7 |
| Standard\_F64-16ams\_v7 | 16 | F64ams\_v7 |
| Standard\_F64-32ams\_v7 | 32 | F64ams\_v7 |

# [FX-family sizes](#tab/family-fx)
| Size name | Active vCPUs | Base size |
| --- | --- | --- |
| Standard\_FX4-2mds\_v2 | 2 | FX4mds\_v2 |
| Standard\_FX8-4mds\_v2 | 4 | FX8mds\_v2 |
| Standard\_FX8-2mds\_v2 | 2 | FX8mds\_v2 |
| Standard\_FX12-6mds\_v2 | 6 | FX12mds\_v2 |
| Standard\_FX16-8mds\_v2 | 8 | FX16mds\_v2 |
| Standard\_FX16-4mds\_v2 | 4 | FX16mds\_v2 |
| Standard\_FX24-12mds\_v2 | 12 | FX24mds\_v2 |
| Standard\_FX24-6mds\_v2 | 6 | FX24mds\_v2 |
| Standard\_FX32-16mds\_v2 | 16 | FX32mds\_v2 |
| Standard\_FX32-8mds\_v2 | 8 | FX32mds\_v2 |
| Standard\_FX48-24mds\_v2 | 24 | FX48mds\_v2 |
| Standard\_FX48-12mds\_v2 | 12 | FX48mds\_v2 |
| Standard\_FX64-32mds\_v2 | 32 | FX64mds\_v2 |
| Standard\_FX64-16mds\_v2 | 16 | FX64mds\_v2 |
| Standard\_FX96-48mds\_v2 | 48 | FX96mds\_v2 |
| Standard\_FX96-24mds\_v2 | 24 | FX96mds\_v2 |
| Standard\_FX4-2ms\_v2 | 2 | FX4ms\_v2 |
| Standard\_FX8-4ms\_v2 | 4 | FX8ms\_v2 |
| Standard\_FX8-2ms\_v2 | 2 | FX8ms\_v2 |
| Standard\_FX12-6ms\_v2 | 6 | FX12ms\_v2 |
| Standard\_FX16-8ms\_v2 | 8 | FX16ms\_v2 |
| Standard\_FX16-4ms\_v2 | 4 | FX16ms\_v2 |
| Standard\_FX24-12ms\_v2 | 12 | FX24ms\_v2 |
| Standard\_FX24-6ms\_v2 | 6 | FX24ms\_v2 |
| Standard\_FX32-16ms\_v2 | 16 | FX32ms\_v2 |
| Standard\_FX32-8ms\_v2 | 8 | FX32ms\_v2 |
| Standard\_FX48-24ms\_v2 | 24 | FX48ms\_v2 |
| Standard\_FX48-12ms\_v2 | 12 | FX48ms\_v2 |
| Standard\_FX64-32ms\_v2 | 32 | FX64ms\_v2 |
| Standard\_FX64-16ms\_v2 | 16 | FX64ms\_v2 |
| Standard\_FX96-48ms\_v2 | 48 | FX96ms\_v2 |
| Standard\_FX96-24ms\_v2 | 24 | FX96ms\_v2 |

# [G-family sizes](#tab/family-G)
| Size name | Active vCPUs | Base size |
| --- | --- | --- |
| Standard\_GS4-8 | 8 | GS4 |
| Standard\_GS4-4 | 4 | GS4 |
| Standard\_GS5-16 | 16 | GS5 |
| Standard\_GS5-8 | 8 | GS5 |

# [D-family sizes](#tab/family-D)
| Size name | Active vCPUs | Base size |
| --- | --- | --- |
| Standard\_DS11-1\_v2 | 1 | DS11\_v2 |
| Standard\_DS12-2\_v2 | 2 | DS12\_v2 |
| Standard\_DS12-1\_v2 | 1 | DS12\_v2 |
| Standard\_DS13-4\_v2 | 4 | DS13\_v2 |
| Standard\_DS13-2\_v2 | 2 | DS13\_v2 |
| Standard\_DS14-8\_v2 | 8 | DS14\_v2 |
| Standard\_DS14-4\_v2 | 4 | DS14\_v2 |

# [H-family sizes](#tab/family-H)
| Size name | Active vCPUs | Base size |
| --- | --- | --- |
| Standard\_HB368rs\_v5 | 368 | HB368rs\_v5 |
| Standard\_HB368\_336rsv5 | 336 | HB368rs\_v5 |
| Standard\_HB368\_288rsv5 | 288 | HB368rs\_v5 |
| Standard\_HB368-240rs\_v5 | 240 | HB368rs\_v5 |
| Standard\_HB368-192rs\_v5 | 192 | HB368rs\_v5 |
| Standard\_HB368-144rs\_v5 | 144 | HB368rs\_v5 |
| Standard\_HB368-96rs\_v5 | 96 | HB368rs\_v5 |
| Standard\_HB368-48rs\_v5 | 48 | HB368rs\_v5 |
| Standard\_HB176rs\_v4 | 176 | HB176rs\_v4 |
| Standard\_HB176-144rs\_v4 | 144 | HB176rs\_v4 |
| Standard\_HB176-96rs\_v4 | 96 | HB176rs\_v4 |
| Standard\_HB176-48rs\_v4 | 48 | HB176rs\_v4 |
| Standard\_HB176-24rs\_v4 | 24 | HB176rs\_v4 |
| Standard\_HX176rs | 176 | HX176rs |
| Standard\_HX176-144rs | 144 | HX176rs |
| Standard\_HX176-96rs | 96 | HX176rs |
| Standard\_HX176-48rs | 48 | HX176rs |
| Standard\_HX176-24rs | 24 | HX176rs |
| Standard\_HB120rs\_v3 | 120 | HB120rs\_v3 |
| Standard\_HB120-96rs\_v3 | 96 | HB120rs\_v3 |
| Standard\_HB120-64rs\_v3 | 64 | HB120rs\_v3 |
| Standard\_HB120-32rs\_v3 | 32 | HB120rs\_v3 |
| Standard\_HB120-16rs\_v3 | 16 | HB120rs\_v3 |
| Standard\_HB120rs\_v2 | 120 | HB120rs\_v2 |
| Standard\_HB120-96rs\_v2 | 96 | HB120rs\_v2 |
| Standard\_HB120-64rs\_v2 | 64 | HB120rs\_v2 |
| Standard\_HB120-32rs\_v2 | 32 | HB120rs\_v2 |
| Standard\_HB120-16rs\_v2 | 16 | HB120rs\_v2 |
| Standard\_HC44rs | 44 | HC44rs |
| Standard\_HC44-16rs | 16 | HC44rs |
| Standard\_HC44-32rs | 32 | HC44rs |

---

## Other standard sizes

- [Compute optimized](sizes-compute)
- [Memory optimized](sizes-memory)
- [Storage optimized](sizes-storage)
- [GPU](sizes-gpu)
- [High performance compute](sizes-hpc)
