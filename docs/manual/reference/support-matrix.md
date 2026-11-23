# Support matrix

This page says which machines the product can migrate, and which it cannot. It is generated from the data the product reads, so it always matches the assessment and the plan.

Each row gives one of two statuses:

| Status | What it means |
|---|---|
| Supported | The product migrates the machine when the assessment finds nothing that holds it back. |
| Not supported | The product does not migrate the machine. The assessment names it and says why. |

A machine keeps its processor maker: Intel stays Intel, and AMD stays AMD.

Dl is Microsoft's name for the D sizes with less memory: 2 GiB for each vCPU. Each Dl size has the letter l after its number, for example D2ls_v5. For "a size in the Dl, D or E family", the product finds the smallest size of each family that fits the machine. A size fits when it has at least the vCPUs and the memory of the machine. The product starts with the one that has the fewest vCPUs, then the least memory. If the machine is on a constrained vCPU size, the product starts with the constrained vCPU size that has the same active vCPUs. The region must have that size. You can choose another in the **Choose each target** step.

## Source sizes

The size series that a machine can move from, with the lifecycle stage Microsoft gives each one. The retirement date is the date Microsoft gives. From one day before that date, a machine on that size is outside the scope of this tool.

The sizes in the two "On" columns are for the example size. The product takes the first of them that the region has and that fits the machine. A cell that gives a target starts with the machine generations that the series takes.

| Size series | Example size | Lifecycle stage | Retirement | On v5 (Generation 1 and Generation 2) | On v6 and v7 (Generation 2 only) | Status | Microsoft page |
|---|---|---|---|---|---|---|---|
| Basic and Standard A-series (A v1) | `Standard_A2` | Retired | 2024-08-31 | None. Microsoft retired this size. | None. Microsoft retired this size. | Not supported | [Microsoft: av1 series retirement](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirement/av1-series-retirement) |
| Av2 | `Standard_A2_v2` | End of Life | 2028-11-15 | Generation 1 and Generation 2. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Generation 2 only. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Supported | [Microsoft: retirements and capacity restrictions](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| Amv2 | `Standard_A2m_v2` | End of Life | 2028-11-15 | Generation 1 and Generation 2. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Generation 2 only. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Supported | [Microsoft: retirements and capacity restrictions](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| B v1 (Bs, Bms, Bls) | `Standard_B2s` | End of Life | 2028-11-15 | Generation 1 and Generation 2. A Bsv2 size first, when the region has one that fits. Else, a size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Generation 2 only. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Supported | [Microsoft: retirements and capacity restrictions](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| D-series (D v1) | `Standard_D2` | End of Life | 2028-05-01 | Generation 1 and Generation 2. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Generation 2 only. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Supported | [Microsoft: retirements and capacity restrictions](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| DS-series (DS v1) | `Standard_DS2` | End of Life | 2028-05-01 | Generation 1 and Generation 2. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Generation 2 only. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Supported | [Microsoft: retirements and capacity restrictions](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| Dv2 | `Standard_D2_v2` | End of Life | 2028-05-01 | Generation 1 and Generation 2. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Generation 2 only. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Supported | [Microsoft: retirements and capacity restrictions](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| DSv2 | `Standard_DS2_v2` | End of Life | 2028-05-01 | Generation 1 and Generation 2. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Generation 2 only. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Supported | [Microsoft: retirements and capacity restrictions](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| F | `Standard_F2` | End of Life | 2028-11-15 | Generation 1 and Generation 2. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Generation 2 only. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Supported | [Microsoft: retirements and capacity restrictions](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| Fs | `Standard_F2s` | End of Life | 2028-11-15 | Generation 1 and Generation 2. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Generation 2 only. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Supported | [Microsoft: retirements and capacity restrictions](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| Fsv2 | `Standard_F2s_v2` | End of Life | 2028-11-15 | Generation 1 and Generation 2. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Generation 2 only. A size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory. | Supported | [Microsoft: retirements and capacity restrictions](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/retirements-and-capacity-restrictions) |
| Dv3, Dsv3 | `Standard_D2s_v3` | End of Life | 2029-11-15 | Generation 1 and Generation 2. Standard_D2ds_v5 or Standard_D2s_v5. | Generation 2 only. v6: Standard_D2ds_v6 or Standard_D2s_v6. v7: Standard_D2ds_v7 or Standard_D2s_v7. | Supported | [Microsoft: end of life sizes list](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/end-of-life-sizes-list) |
| Ev3, Esv3 | `Standard_E2s_v3` | End of Life | 2029-11-15 | Generation 1 and Generation 2. Standard_E2ds_v5 or Standard_E2s_v5. | Generation 2 only. v6: Standard_E2ds_v6 or Standard_E2s_v6. v7: Standard_E2ds_v7 or Standard_E2s_v7. | Supported | [Microsoft: end of life sizes list](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/end-of-life-sizes-list) |
| Dv4 | `Standard_D2_v4` | Extended | None announced | Generation 1 and Generation 2. Standard_D2_v5. | Generation 2 only. v6: Standard_D2s_v6. v7: Standard_D2s_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Ddv4 | `Standard_D2d_v4` | Extended | None announced | Generation 1 and Generation 2. Standard_D2d_v5. | Generation 2 only. v6: Standard_D2ds_v6. v7: Standard_D2ds_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Dsv4, Ddsv4 | `Standard_D2ds_v4` | Extended | None announced | Generation 1 and Generation 2. Standard_D2ds_v5. | Generation 2 only. v6: Standard_D2ds_v6. v7: Standard_D2ds_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Dav4 | `Standard_D2a_v4` | Extended | None announced | Generation 1 and Generation 2. Standard_D2ads_v5 or Standard_D2as_v5. | Generation 2 only. v6: Standard_D2ads_v6 or Standard_D2as_v6. v7: Standard_D2ads_v7 or Standard_D2as_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Dasv4 | `Standard_D2as_v4` | Extended | None announced | Generation 1 and Generation 2. Standard_D2ads_v5 or Standard_D2as_v5. | Generation 2 only. v6: Standard_D2ads_v6 or Standard_D2as_v6. v7: Standard_D2ads_v7 or Standard_D2as_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Ev4 | `Standard_E2_v4` | Extended | None announced | Generation 1 and Generation 2. Standard_E2_v5. | Generation 2 only. v6: Standard_E2s_v6. v7: Standard_E2s_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Edv4 | `Standard_E2d_v4` | Extended | None announced | Generation 1 and Generation 2. Standard_E2d_v5. | Generation 2 only. v6: Standard_E2ds_v6. v7: Standard_E2ds_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Esv4, Edsv4 | `Standard_E2ds_v4` | Extended | None announced | Generation 1 and Generation 2. Standard_E2ds_v5. | Generation 2 only. v6: Standard_E2ds_v6. v7: Standard_E2ds_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Eav4 | `Standard_E2a_v4` | Extended | None announced | Generation 1 and Generation 2. Standard_E2ads_v5 or Standard_E2as_v5. | Generation 2 only. v6: Standard_E2ads_v6 or Standard_E2as_v6. v7: Standard_E2ads_v7 or Standard_E2as_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Easv4 | `Standard_E2as_v4` | Extended | None announced | Generation 1 and Generation 2. Standard_E2ads_v5 or Standard_E2as_v5. | Generation 2 only. v6: Standard_E2ads_v6 or Standard_E2as_v6. v7: Standard_E2ads_v7 or Standard_E2as_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Dv5 | `Standard_D2_v5` | Extended | None announced | None. The machine is already on v5. | Generation 2 only. v6: Standard_D2s_v6. v7: Standard_D2s_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Ddv5 | `Standard_D2d_v5` | Extended | None announced | None. The machine is already on v5. | Generation 2 only. v6: Standard_D2ds_v6. v7: Standard_D2ds_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Dsv5, Ddsv5 | `Standard_D2ds_v5` | Extended | None announced | None. The machine is already on v5. | Generation 2 only. v6: Standard_D2ds_v6. v7: Standard_D2ds_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Dlsv5, Dldsv5 | `Standard_D2lds_v5` | Extended | None announced | None. The machine is already on v5. | Generation 2 only. v6: Standard_D2lds_v6. v7: Standard_D2lds_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Dasv5, Dadsv5 | `Standard_D2ads_v5` | Extended | None announced | None. The machine is already on v5. | Generation 2 only. v6: Standard_D2ads_v6. v7: Standard_D2ads_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Dalsv5, Daldsv5 | `Standard_D2alds_v5` | Extended | None announced | None. The machine is already on v5. | Generation 2 only. v6: Standard_D2alds_v6. v7: Standard_D2alds_v7. | Supported | [Microsoft: lifecycle overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview) |
| Ev5 | `Standard_E2_v5` | Extended | None announced | None. The machine is already on v5. | Generation 2 only. v6: Standard_E2s_v6. v7: Standard_E2s_v7. | Supported | [Microsoft: sizes v5 modernization overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/sizes-v5-modernization-overview) |
| Edv5 | `Standard_E2d_v5` | Extended | None announced | None. The machine is already on v5. | Generation 2 only. v6: Standard_E2ds_v6. v7: Standard_E2ds_v7. | Supported | [Microsoft: sizes v5 modernization overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/sizes-v5-modernization-overview) |
| Esv5, Edsv5 | `Standard_E2ds_v5` | Extended | None announced | None. The machine is already on v5. | Generation 2 only. v6: Standard_E2ds_v6. v7: Standard_E2ds_v7. | Supported | [Microsoft: sizes v5 modernization overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/sizes-v5-modernization-overview) |
| Ebsv5, Ebdsv5 | `Standard_E2bds_v5` | Extended | None announced | None. The machine is already on v5. | Generation 2 only. v6: Standard_E2bds_v6. v7: none, because Microsoft lists no size of this name. | Supported | [Microsoft: sizes v5 modernization overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/sizes-v5-modernization-overview) |
| Easv5, Eadsv5 | `Standard_E2ads_v5` | Extended | None announced | None. The machine is already on v5. | Generation 2 only. v6: Standard_E2ads_v6. v7: Standard_E2ads_v7. | Supported | [Microsoft: sizes v5 modernization overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/sizes-v5-modernization-overview) |

A size series that is not in this table is outside the scope of this tool. A constrained vCPU size belongs to the series of its letters: E8-4ds_v5 is an Edsv5 size. An isolated size, such as E104i_v5, gets no target, because a person chooses its size. A machine on a v6 or v7 size cannot move to v5. On v5, a Generation 1 machine can also choose a size in the Dl, D or E family by its vCPUs and memory. The size in the table stays its first choice. The Windows and Machine generation tables below can also stop a machine from going to a series.

## Target series

You choose the size series for each machine in the **Choose each target** step. A move to v6 or v7 changes the disk controller from SCSI to NVMe. A move to v5 is a resize, and the disk controller stays SCSI.

| | v5 | v6 | v7 |
|---|---|---|---|
| Families | D, E | D, E | D, E, F |
| Disk controller | SCSI | NVMe | NVMe |
| Machine generation | Generation 1 and Generation 2 | Generation 2 only | Generation 2 only |
| Windows | Windows Server 2016 and later | Windows Server 2019 and later | Windows Server 2019 and later |
| Accelerated networking | Required on the Intel D and Intel E sizes. Supported on the other sizes. | Required on every size. | Supported |
| Microsoft Azure Network Adapter (MANA) | Sizes with an Intel processor can give MANA. Sizes with an AMD processor do not give MANA. | Every size can give MANA. | Every size can give MANA. |
| Lifecycle stage | Extended | Current | Current |

Bsv2 is one series of the B family. It is not a generation, as v5, v6 and v7 are. The product offers a Bsv2 size only to a machine on a B v1 size. A move to Bsv2 is a resize, and the disk controller stays SCSI.

| Item | Bsv2, for a machine on a B v1 size |
|---|---|
| Choose it as | v5. The product then offers the Bsv2 size first, when the region has one that fits the machine. |
| Families | B, for a machine on a B v1 size only |
| Disk controller | SCSI |
| Machine generation | Generation 1 and Generation 2 |
| Windows | Windows Server 2016 and later |
| Accelerated networking | Supported |
| Microsoft Azure Network Adapter (MANA) | Every size can give MANA. |
| Lifecycle stage | Current |

Microsoft lists F among its v7 target families, as Fasv7, an AMD family. A machine on an F, Fs or Fsv2 size has an Intel processor, and a machine keeps its processor maker. So the product chooses no F size for it. That machine gets a size in the Dl, D or E family: the smallest with at least the machine's vCPUs and memory.

The other differences between the series are in [Limits](limits.md). Read more: [Microsoft: sizes v5 modernization overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/sizes-v5-modernization-overview), [Microsoft: sizes v6 v7 modernization overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/sizes-v6-v7-modernization-overview)

## Windows

The product reads the version that the machine reports it runs. When the machine does not report a version, it reads the version from the image.

| Operating system | v5 (and Bsv2 for a B v1 machine) | v6 and v7 | Why | Microsoft page |
|---|---|---|---|---|
| Windows Server 2019 and later | Supported | Supported | Every target series takes this version. | [Microsoft: NVMe questions and answers](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-faqs) |
| Windows Server 2016 | Supported | Not supported | Azure supports NVMe disks on Windows Server 2019 and later. This machine runs an older version of Windows. The product reads the version that the machine reports it runs. When the machine does not report a version, for example when it is stopped, the product reads the version from its image. | [Microsoft: NVMe questions and answers](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-faqs) |
| Windows Server older than 2016 | Not supported | Not supported | This machine runs a Windows version older than 2016, which has PowerShell 4.0 or older. The steps the product runs inside a machine have run only on PowerShell 5.1. A move to v5 is held. Azure supports NVMe disks on Windows Server 2019 and later. | [Microsoft: modernize to the v5 series](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/sizes-v5-modernization-overview) |
| Windows client (Windows 10 and Windows 11) | Not supported | Not supported | The machine runs Windows 10, Windows 11 or a Virtual Desktop image. The product migrates server operating systems only. | [Microsoft: Windows client images in Azure](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/client-images) |

A Windows machine with a Marketplace purchase plan, for example from a Windows Server preview image, is outside the scope of this tool.

## Linux images

The product migrates a Linux machine when Microsoft publishes or endorses its image. The list goes by the image publisher in Azure.

| Distribution | Azure publisher | Status | Why |
|---|---|---|---|
| Data Science Virtual Machine | microsoft-dsvm | Supported | Microsoft publishes this image. |
| CBL-Mariner | MicrosoftCBLMariner | Not supported | This image is on the list as not supported. The product does not move this machine. |
| Azure Linux 3.0 | MicrosoftCBLMariner | Not supported | This image is on the list as not supported. The product does not move this machine. |
| Azure Linux 4.0 | microsoftazurelinux | Not supported | This image is on the list as not supported. The product does not move this machine. |
| Ubuntu | Canonical | Supported | Microsoft endorses this distribution on Azure. |
| Red Hat Enterprise Linux | RedHat | Supported | Microsoft endorses this distribution on Azure. |
| SUSE Linux Enterprise Server | SUSE | Supported | Microsoft endorses this distribution on Azure. |
| openSUSE Leap | SUSE | Not supported | This image is on the list as not supported. The product does not move this machine. |
| Debian | Debian | Supported | Microsoft endorses this distribution on Azure. |
| Oracle Linux | Oracle | Supported | Microsoft endorses this distribution on Azure. |
| CentOS | OpenLogic | Not supported | This image is on the list as not supported. The product does not move this machine. |
| CIS hardened images | center-for-internet-security-inc | Not supported | This image is on the list as not supported. The product does not move this machine. |
| Any other image | Any other | Not supported | This machine's image is not on the product's supported list. The list carries a date and a source, and Azure has no such list of its own. The product does not move this machine. The support matrix in the manual lists the images that the product moves. |

Some editions of these distributions have a Marketplace purchase plan: Ubuntu Pro, RHEL BYOS and the SUSE offers with a name that ends in -llc. A machine with a purchase plan is outside the scope of this tool, whatever its distribution. The standard images of each distribution in this table have no plan.

Read more: [Microsoft: Marketplace purchase plan information](https://learn.microsoft.com/en-us/azure/virtual-machines/marketplace-images)

## Linux releases for NVMe

Microsoft lists the Linux releases that support NVMe disks. The product does not move a Linux machine on another release to v6 or v7. The product can move that machine to v5. v5 keeps the SCSI disk controller.

The product reads the release that the Azure Linux Agent reports. If the agent reports no release, the product reads the release from the image of the machine. If the scan cannot compare the release, the assessment shows a warning. The machine can still move.

A release on this list must also be on the list of Linux images. The MANA kernel rules below also apply.

| Linux release |
|---|
| Azure Linux 3.0 |
| AlmaLinux 8.x |
| AlmaLinux 9.x |
| Debian 11 |
| Debian 12 |
| Oracle Linux 7.9 |
| Oracle Linux 8.5 and newer |
| Oracle Linux 9.0 and newer |
| RHEL 7.9 |
| RHEL 8.6 and newer |
| RHEL 9.0 and newer |
| SLES 15 SP4 and newer |
| SLES-for-SAP 15 SP3 and newer |
| Ubuntu 18.04 |
| Ubuntu 20.04 |
| Ubuntu 22.04 |
| Ubuntu 24.04 |
| Rocky Linux 8.10 |
| Rocky Linux 9.6 |

Read more: [Microsoft: Linux images that support NVMe](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface)

## End of standard support of a Linux release

Each Linux vendor ends the standard support of a release on a date. Microsoft supports accelerated networking only on releases that the vendor has not marked as end of life. A vendor can sell extended support after the end of standard support. A machine on such a release can still move.

The assessment shows the date. Before the move, Checking stops the machine with the reason **The vendor ended standard support for this Linux release**. An approver can accept the release for that machine. The product reads the release that the Azure Linux Agent reports. The image of a machine shows the lowest release that the machine can run. If the release is from the image, the product does not show it as past its date.

| Linux release | Vendor | End of standard support | Vendor page |
|---|---|---|---|
| Ubuntu 16.04 LTS | Canonical | April 2021 | [Canonical](https://ubuntu.com/about/release-cycle) |
| Ubuntu 18.04 LTS | Canonical | May 2023 | [Canonical](https://ubuntu.com/about/release-cycle) |
| Ubuntu 20.04 LTS | Canonical | May 2025 | [Canonical](https://ubuntu.com/about/release-cycle) |
| Ubuntu 22.04 LTS | Canonical | May 2027 | [Canonical](https://ubuntu.com/about/release-cycle) |
| Ubuntu 24.04 LTS | Canonical | May 2029 | [Canonical](https://ubuntu.com/about/release-cycle) |
| Ubuntu 26.04 LTS | Canonical | May 2031 | [Canonical](https://ubuntu.com/about/release-cycle) |
| Red Hat Enterprise Linux 6 | Red Hat | 30 November 2020 | [Red Hat](https://access.redhat.com/product-life-cycles/api/v1/products?name=Red%20Hat%20Enterprise%20Linux%20Legacy%20Offerings) |
| Red Hat Enterprise Linux 7 | Red Hat | 30 June 2024 | [Red Hat](https://access.redhat.com/product-life-cycles/api/v1/products?name=Red%20Hat%20Enterprise%20Linux%20Legacy%20Offerings) |
| Red Hat Enterprise Linux 8 | Red Hat | 31 May 2029 | [Red Hat](https://access.redhat.com/product-life-cycles/api/v1/products?name=Red%20Hat%20Enterprise%20Linux) |
| Red Hat Enterprise Linux 9 | Red Hat | 31 May 2032 | [Red Hat](https://access.redhat.com/product-life-cycles/api/v1/products?name=Red%20Hat%20Enterprise%20Linux) |
| Red Hat Enterprise Linux 10 | Red Hat | 31 May 2035 | [Red Hat](https://access.redhat.com/product-life-cycles/api/v1/products?name=Red%20Hat%20Enterprise%20Linux) |
| SUSE Linux Enterprise Server 12 SP5 | SUSE | 31 October 2024 | [SUSE](https://www.suse.com/lifecycle/) |
| SUSE Linux Enterprise Server 15 SP1 | SUSE | 31 January 2021 | [SUSE](https://www.suse.com/lifecycle/) |
| SUSE Linux Enterprise Server 15 SP2 | SUSE | 31 December 2021 | [SUSE](https://www.suse.com/lifecycle/) |
| SUSE Linux Enterprise Server 15 SP3 | SUSE | 31 December 2022 | [SUSE](https://www.suse.com/lifecycle/) |
| SUSE Linux Enterprise Server 15 SP4 | SUSE | 31 December 2023 | [SUSE](https://www.suse.com/lifecycle/) |
| SUSE Linux Enterprise Server 15 SP5 | SUSE | 31 December 2024 | [SUSE](https://www.suse.com/lifecycle/) |
| SUSE Linux Enterprise Server 15 SP6 | SUSE | 31 December 2025 | [SUSE](https://www.suse.com/lifecycle/) |
| SUSE Linux Enterprise Server 15 SP7 | SUSE | 31 July 2031 | [SUSE](https://www.suse.com/lifecycle/) |
| SUSE Linux Enterprise Server 16.0 | SUSE | 30 November 2027 | [SUSE](https://www.suse.com/lifecycle/) |
| Oracle Linux 6 | Oracle | March 2021 | [Oracle](https://www.oracle.com/a/ocom/docs/elsp-lifetime-069338.pdf) |
| Oracle Linux 7 | Oracle | December 2024 | [Oracle](https://www.oracle.com/a/ocom/docs/elsp-lifetime-069338.pdf) |
| Oracle Linux 8 | Oracle | July 2029 | [Oracle](https://www.oracle.com/a/ocom/docs/elsp-lifetime-069338.pdf) |
| Oracle Linux 9 | Oracle | June 2032 | [Oracle](https://www.oracle.com/a/ocom/docs/elsp-lifetime-069338.pdf) |
| Oracle Linux 10 | Oracle | June 2035 | [Oracle](https://www.oracle.com/a/ocom/docs/elsp-lifetime-069338.pdf) |
| AlmaLinux 8 | AlmaLinux OS Foundation | 31 May 2029 | [AlmaLinux OS Foundation](https://wiki.almalinux.org/release-notes/) |
| AlmaLinux 9 | AlmaLinux OS Foundation | 31 May 2032 | [AlmaLinux OS Foundation](https://wiki.almalinux.org/release-notes/) |
| AlmaLinux 10 | AlmaLinux OS Foundation | 31 May 2035 | [AlmaLinux OS Foundation](https://wiki.almalinux.org/release-notes/) |
| Rocky Linux 8 | Rocky Enterprise Software Foundation | 31 May 2029 | [Rocky Enterprise Software Foundation](https://docs.rockylinux.org/10/releases/) |
| Rocky Linux 9 | Rocky Enterprise Software Foundation | 31 May 2032 | [Rocky Enterprise Software Foundation](https://docs.rockylinux.org/10/releases/) |
| Rocky Linux 10 | Rocky Enterprise Software Foundation | 31 May 2035 | [Rocky Enterprise Software Foundation](https://docs.rockylinux.org/10/releases/) |
| Debian 10 | Debian | 10 September 2022 | [Debian](https://www.debian.org/releases/) |
| Debian 11 | Debian | 14 August 2024 | [Debian](https://www.debian.org/releases/) |
| Debian 12 | Debian | 11 July 2026 | [Debian](https://www.debian.org/releases/bookworm/) |
| Debian 13 | Debian | 9 August 2028 | [Debian](https://www.debian.org/releases/) |

Read more: [Microsoft: accelerated networking](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-overview)

## What a move to NVMe needs

A move to v6 or v7 attaches the disks over NVMe. A move to v5, or to Bsv2 for a B v1 machine, keeps the SCSI disk controller. This table does not apply to it.

| Part | What it needs | Microsoft page |
|---|---|---|
| Image | Azure reports the disk controllers that each image supports, and it must report NVMe. When it reports SCSI only, the machine cannot go to v6 or v7, because it would not start after the migration. Choose v5 for that machine. | [Microsoft: NVMe on Azure machines](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface) |
| Linux | The Linux start-up image must load the NVMe driver. Without it, the machine cannot find its root disk after the migration. The product prepares this during the migration. | [Microsoft: NVMe on Azure machines](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface) |
| Windows | Windows starts the NVMe driver only when that driver is enabled. Without it, Windows cannot find its disks on a v6 or v7 size. The product prepares this during the migration. | [Microsoft: NVMe on Azure machines](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface) |
| Machine generation | Generation 2 only. | [Microsoft: Generation 2 machines](https://learn.microsoft.com/en-us/azure/virtual-machines/generation-2) |

## Linux kernel for MANA

Azure does not update the network drivers inside a machine. A Linux machine needs a kernel with the MANA driver to use accelerated networking on a size that gives MANA. The product checks the kernel before the move. These are the minimum kernels Microsoft lists. A release that Microsoft does not list for MANA, such as Ubuntu 20.04, gets no v6, v7, Bsv2 or Intel v5 size. An AMD machine on it gets AMD v5. For a distribution that is not in this table, the kernel must be 6.14 or later. A distribution must also be on the list of Linux images.

| Distribution | Version | Minimum kernel |
|---|---|---|
| AlmaLinux | 9.6 | 5.14.0-570.52.1 |
| AlmaLinux | 10.0 | 6.12.0-108 |
| Azure Linux | 3 | Any 6.6 |
| Azure Linux | 4 | Any 6.18 |
| Debian | 12 | 6.12.21 |
| Debian | 13 | 6.12.21 |
| Oracle Linux | 9 | 5.14.0-570.52.1 |
| Oracle Linux | 10 | 6.12.0-108 |
| Rocky Linux | 9.6 | 5.14.0-570.52.1 |
| Rocky Linux | 10.0 | 6.12.0-108 |
| Red Hat Enterprise Linux | 9.6 | 5.14.0-570.52.1 |
| Red Hat Enterprise Linux | 10.0 | 6.12.0-108 |
| SUSE Linux Enterprise Server | 15.5 | 5.14.21-150500.55.121.2 |
| SUSE Linux Enterprise Server | 15.6 | 6.4.0-150600.23.73.1 |
| SUSE Linux Enterprise Server | 15.7 | 6.4.0-150700.53.16.1 |
| SUSE Linux Enterprise Server | 16 | 6.12.0-160000.5.1 |
| Ubuntu | 22.04 | 5.15.0-1096.105 |
| Ubuntu | 24.04 | 6.8.0-1041.47 |
| Ubuntu | 26.04 | 7.0.0-14.14 |
| Oracle Linux, Unbreakable Enterprise Kernel | Any | 6.12.0-100.28.2 |

Read more: [Microsoft: MANA on Linux, and the minimum kernel for each distribution](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-linux)

## Machine generation

| Machine generation | v5 (and Bsv2 for a B v1 machine) | v6 and v7 | Why | Microsoft page |
|---|---|---|---|---|
| Generation 2 | Supported | Supported | Every target series takes Generation 2. | [Microsoft: Generation 2 machines](https://learn.microsoft.com/en-us/azure/virtual-machines/generation-2) |
| Generation 1 | Supported | Not supported | This machine is Generation 1. The v6 and v7 sizes need Generation 2. The v5 sizes take Generation 1 with a resize on SCSI. The Choose each target step shows v5 for this machine when a v5 size fits it. When no v5 size fits it, this machine is outside the scope of this tool. | [Microsoft: Generation 2 machines](https://learn.microsoft.com/en-us/azure/virtual-machines/generation-2) |

## Machines the product does not move

The product does not migrate these machines to any size series. The assessment names each one, with the reason.

| Machine | Why | What to do | Status | Microsoft page |
|---|---|---|---|---|
| Member of a virtual machine scale set | The scale set owns this machine. The scale set decides its size and its image. | Change the size in the scale set model, then let the scale set roll the change out. | Not supported | [Microsoft: change a scale set](https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-upgrade-scale-set) |
| Machine in a resource group that a platform manages | A service declares this resource group as its own: an AKS cluster, an Azure Red Hat OpenShift cluster, a Databricks workspace or another service. The service creates and replaces the machines in it. | Change the size in the settings of the cluster, the workspace or the service. The service then replaces its machines. | Not supported | [Microsoft: change the size of a Kubernetes cluster's machines](https://learn.microsoft.com/en-us/azure/aks/resize-node-pool) |
| Virtual Desktop session host | A Virtual Desktop host pool lists this machine as a session host. People sign in to it for their desktops. | Add new session hosts on the new size to the host pool, drain the old ones, then remove them. | Not supported | [Microsoft: add session hosts to a host pool](https://learn.microsoft.com/en-us/azure/virtual-desktop/add-session-hosts-host-pool) |
| Client operating system | The machine runs Windows 10, Windows 11 or a Virtual Desktop image. The product migrates server operating systems only. | Do nothing in the product. Manage the machine with the software that manages your desktops. | Not supported | [Microsoft: Windows client images in Azure](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/client-images) |
| Machine in an Azure CycleCloud cluster | Azure CycleCloud adds tags to each machine of its clusters: CycleCloudCluster and CycleCloudNodeArray, or ClusterId with ClusterName on CycleCloud 8.2 and earlier. This machine has them, in the form that CycleCloud gives. CycleCloud makes and changes the machines of its cluster. | Change the size in the settings of the CycleCloud cluster. CycleCloud then makes its machines on the new size. | Not supported | [Microsoft: tagging nodes in Azure CycleCloud](https://learn.microsoft.com/en-us/azure/cyclecloud/how-to/tag-nodes) |
| Machine on a dedicated host | Azure records a dedicated host or a host group on this machine. A machine on a dedicated host is outside the scope of this tool. | Do nothing in the product. | Not supported | [Microsoft: Azure Dedicated Hosts](https://learn.microsoft.com/en-us/azure/virtual-machines/dedicated-hosts/overview) |
| Machine with hibernation enabled | Azure records that hibernation is enabled on this machine. A machine with hibernation enabled is outside the scope of this tool. | Do nothing in the product. | Not supported | [Microsoft: hibernation overview](https://learn.microsoft.com/en-us/azure/virtual-machines/hibernate-resume) |
| Machine on an Arm64 size | Microsoft lists only Intel and AMD sizes as v5, v6 and v7 targets. An Arm64 size, such as Dpsv5, is outside the scope of this tool. | Keep this machine on its size. Microsoft names no Arm64 target family. | Not supported | [Microsoft: sizes v6 v7 modernization overview](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/sizes-v6-v7-modernization-overview) |
| Confidential machine | This is a confidential machine, on a size such as DCasv5 or ECasv5. The product does not move confidential sizes. Confidential sizes have their own upgrade path. | Follow Microsoft's confidential computing guidance for this machine. The product does not change it. | Not supported | [Microsoft: confidential machines](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-vm-overview) |
| Operating system disk is not a managed disk | This machine starts from an unmanaged disk in a storage account. Every step of this migration works on managed disks. | Convert this machine to managed disks. Then assess this machine again. | Not supported | [Microsoft: convert to managed disks](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/convert-unmanaged-to-managed-disks) |
| Network virtual appliance | Network traffic flows through this machine. A migration stops the machine, and the traffic stops with it. The product finds an appliance from its Marketplace image or its Marketplace purchase plan, with the list in a Microsoft Azure Policy definition. | Deploy the new appliance beside this machine and move the traffic across. The product does not do that. | Not supported | [Microsoft: appliances that stay available](https://learn.microsoft.com/en-us/azure/architecture/networking/guide/network-virtual-appliance-high-availability) |
| HPC or FPGA size | HPC and FPGA sizes are outside the scope of this tool, so it does not move this machine. Microsoft has its own route for these sizes. | Follow the retirement guide from Microsoft for this series. The End of Life list from Microsoft links the guide for each series. | Not supported | [Microsoft: End of Life size series](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/end-of-life-sizes-list) |
| Ls or Lsv2 size | Ls and Lsv2 sizes are outside the scope of this tool, so it does not move this machine. Microsoft moves them to newer L series sizes. | Follow the modernization guide from Microsoft. It names Lsv3, Lasv3, Lsv4 and Lasv4. | Not supported | [Microsoft: modernization guide for retired sizes](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide) |
| G or GS size | G and GS sizes are outside the scope of this tool, so it does not move this machine. Microsoft moves them to L series sizes. | Follow the modernization guide from Microsoft. It names Lsv3, Lasv3, Lsv4 and Lasv4. | Not supported | [Microsoft: modernization guide for retired sizes](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide) |
| GPU size | GPU sizes are outside the scope of this tool, so it does not move this machine. The GPU families are NC, ND, NG and NV. | Keep this machine on its GPU size. If its series is End of Life, the End of Life list from Microsoft links the guide for that series. | Not supported | [Microsoft: End of Life size series](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/end-of-life-sizes-list) |
| Retired size | Microsoft retires the size series of this machine on a date. For example, the Basic and Standard A-series retired on August 31, 2024. From one day before that date, a machine on that size is outside the scope of this tool, so it does not move this machine. | Resize the machine to a size that Microsoft supports, and start it. Then assess the machine again. The modernization guide from Microsoft names the sizes for each retired series. | Not supported | [Microsoft: modernization guide for retired sizes](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide) |
| More than 32 data disks | This machine has more than 32 data disks. A machine with more than 32 data disks is outside the scope of this tool, so it does not move this machine. | Keep this machine on its size. To move it, detach the data disks that it does not use, until it has 32 or fewer. Then assess the machine again. | Not supported | [Microsoft: sizes for virtual machines, with the data disk limit of each size](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/overview) |
| SAP workload | SAP supports its software only on the sizes SAP certifies. That list is SAP Note 1928533, and it needs an SAP account to read. The product cannot read it, so it cannot say whether the new size is certified. | Migrate this machine the SAP way. Read SAP Note 1928533, choose a certified size, and follow the SAP guidance. The product does not move SAP machines. | Not supported | [Microsoft: Azure certifications for SAP](https://learn.microsoft.com/en-us/azure/sap/workloads/certifications) |
| The operating system disk is ephemeral | This machine keeps its operating system disk on the host, not in a disk resource. The disk is empty again every time the machine stops, and the product cannot copy it or move it. | Deploy this machine again on the new size, from whatever builds it. Nothing on an ephemeral disk is kept, so there is nothing to carry across. | Not supported | [Microsoft: ephemeral operating system disks](https://learn.microsoft.com/en-us/azure/virtual-machines/ephemeral-os-disks) |
| Storage or backup appliance | This machine is a storage or backup appliance from a vendor. The vendor certifies the sizes that the appliance supports. Microsoft says to treat these appliances like network virtual appliances. The product finds them from its own list of Marketplace images, which is not a Microsoft list. | Ask the vendor which sizes they support, and how to move the appliance. This machine is outside the scope of this tool. | Not supported | [Microsoft: storage and backup virtual appliances](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/sizes-v6-v7-modernization-plan) |
| Machine in an Azure managed application | An Azure managed application manages the resource group of this machine. The vendor of the application owns the machine, and the vendor certifies its sizes. | Ask the vendor of the managed application to change the size. This machine is outside the scope of this tool. | Not supported | [Microsoft: Azure managed applications](https://learn.microsoft.com/en-us/azure/azure-resource-manager/managed-applications/overview) |
| Machine with a Marketplace purchase plan | Azure records a Marketplace purchase plan on this machine. The publisher of the image sells it under that plan. Examples are Ubuntu Pro, RHEL BYOS and the SUSE offers with a name that ends in -llc. The assessment names the plan publisher, the plan product and the plan name. | Move this machine in the way that the publisher of the plan tells you. A machine with a purchase plan is outside the scope of this tool. | Not supported | [Microsoft: Marketplace purchase plan information](https://learn.microsoft.com/en-us/azure/virtual-machines/marketplace-images) |
| Failover cluster on a shared disk | A data disk of this machine is a shared disk. Its maxShares setting is more than 1, so other machines use the same disk. A migration stops this machine as if it were alone in the cluster. | Move the cluster one machine at a time, in the way that the cluster software tells you. This machine is outside the scope of this tool. | Not supported | [Microsoft: shared disks](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-shared) |
| SQL Server Always On availability group member | This machine is a member of a SQL Server Always On availability group. Its SQL virtual machine resource in Azure names the group. | Move the availability group one machine at a time. Fail over before you move a machine. This machine is outside the scope of this tool. | Not supported | [Microsoft: availability groups for SQL Server on Azure virtual machines](https://learn.microsoft.com/en-us/azure/azure-sql/virtual-machines/windows/availability-group-overview) |

<!-- next:begin -->

---

**Next:** [What an assessment can find](assessment-findings.md)

<!-- next:end -->
