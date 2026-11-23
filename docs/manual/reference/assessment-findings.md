# What an assessment can find

Every finding an assessment can give, in the words the dashboard uses. This page is generated from the product's own list, so it always matches the screen.

An assessment gives four kinds of answer. A machine that **another platform owns** is left alone: the assessment names it and does nothing more. A finding that **holds a machine back** means the machine cannot migrate, to every size series or to some, until somebody acts. A finding under **what to check before the move** lets the machine move, after a person checks the thing it names. A finding that says **what the product will prepare** means the product does it itself during the migration, and nothing needs doing first.

The assessment also gives each machine a **workload type**, with the Azure facts that decided it. The last part of this page names each type.

## What the assessment leaves alone

The assessment names these machines and never plans a move for them. A machine that another Azure service manages changes its size through that service.

### Member of a virtual machine scale set

The scale set owns this machine. The scale set decides its size and its image.

**What to do:** Change the size in the scale set model, then let the scale set roll the change out.

Read more: [Microsoft: change a scale set](https://learn.microsoft.com/en-us/azure/virtual-machine-scale-sets/virtual-machine-scale-sets-upgrade-scale-set)


### Machine in a resource group that a platform manages

A service declares this resource group as its own: an AKS cluster, an Azure Red Hat OpenShift cluster, a Databricks workspace or another service. The service creates and replaces the machines in it.

**What to do:** Change the size in the settings of the cluster, the workspace or the service. The service then replaces its machines.

Read more: [Microsoft: change the size of a Kubernetes cluster's machines](https://learn.microsoft.com/en-us/azure/aks/resize-node-pool)


### Virtual Desktop session host

A Virtual Desktop host pool lists this machine as a session host. People sign in to it for their desktops.

**What to do:** Add new session hosts on the new size to the host pool, drain the old ones, then remove them.

Read more: [Microsoft: add session hosts to a host pool](https://learn.microsoft.com/en-us/azure/virtual-desktop/add-session-hosts-host-pool)


### Client operating system

The machine runs Windows 10, Windows 11 or a Virtual Desktop image. The product migrates server operating systems only.

**What to do:** Do nothing in the product. Manage the machine with the software that manages your desktops.

Read more: [Microsoft: Windows client images in Azure](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/client-images)


### Machine in an Azure CycleCloud cluster

Azure CycleCloud adds tags to each machine of its clusters: CycleCloudCluster and CycleCloudNodeArray, or ClusterId with ClusterName on CycleCloud 8.2 and earlier. This machine has them, in the form that CycleCloud gives. CycleCloud makes and changes the machines of its cluster.

**What to do:** Change the size in the settings of the CycleCloud cluster. CycleCloud then makes its machines on the new size.

Read more: [Microsoft: tagging nodes in Azure CycleCloud](https://learn.microsoft.com/en-us/azure/cyclecloud/how-to/tag-nodes)


### Machine on a dedicated host

Azure records a dedicated host or a host group on this machine. A machine on a dedicated host is outside the scope of this tool.

**What to do:** Do nothing in the product.

Read more: [Microsoft: Azure Dedicated Hosts](https://learn.microsoft.com/en-us/azure/virtual-machines/dedicated-hosts/overview)


### Machine with hibernation enabled

Azure records that hibernation is enabled on this machine. A machine with hibernation enabled is outside the scope of this tool.

**What to do:** Do nothing in the product.

Read more: [Microsoft: hibernation overview](https://learn.microsoft.com/en-us/azure/virtual-machines/hibernate-resume)

## What holds a machine back

A finding that applies to every size series stops the machine. A finding that names some size series closes only those, and the machine can still move to the others. The report shows that kind under **What limits the target**. It counts the machine under **Some targets only** while at least one size series stays open to it. When the findings close every series, it counts the machine under **Cannot yet**.

### Generation 1 machine

This machine is Generation 1. The v6 and v7 sizes need Generation 2. The v5 sizes take Generation 1 with a resize on SCSI.

**This applies to v6 and v7 only. A move to v5 does not need this.**

**What to do:** The Choose each target step shows v5 for this machine when a v5 size fits it. When no v5 size fits it, this machine is outside the scope of this tool.

Read more: [Microsoft: Generation 2 machines](https://learn.microsoft.com/en-us/azure/virtual-machines/generation-2)


### Confidential machine

This is a confidential machine, on a size such as DCasv5 or ECasv5. The product does not move confidential sizes. Confidential sizes have their own upgrade path.

**What to do:** Follow Microsoft's confidential computing guidance for this machine. The product does not change it.

Read more: [Microsoft: confidential machines](https://learn.microsoft.com/en-us/azure/confidential-computing/confidential-vm-overview)


### Image is not on the supported list

This machine's image is not on the product's supported list. The list carries a date and a source, and Azure has no such list of its own.

**What to do:** The product does not move this machine. The support matrix in the manual lists the images that the product moves.

Read more: [Microsoft: migrate to v6 and v7 sizes](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/sizes-v6-v7-modernization-overview)


### Image does not support NVMe disks

Azure reports that this image supports the SCSI disk controller only. The v6 and v7 sizes attach disks over NVMe, so this machine would not start after the migration.

**This applies to v6 and v7 only. A move to v5 does not need this.**

**What to do:** Move this machine to an image that supports NVMe. Azure publishes the disk controllers each image supports. Or choose v5 for this machine in the Choose each target step. v5 keeps the SCSI disk controller.

Read more: [Microsoft: NVMe on Azure machines](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface)


### Windows is older than Windows Server 2019

Azure supports NVMe disks on Windows Server 2019 and later. This machine runs an older version of Windows. The product reads the version that the machine reports it runs. When the machine does not report a version, for example when it is stopped, the product reads the version from its image.

**This applies to v6 and v7 only. A move to v5 does not need this.**

**What to do:** For v6 or v7, upgrade Windows to Windows Server 2019 or later. Or deploy the machine again from a newer image. Start the machine, then assess it again. If this machine runs Windows Server 2016, you can choose v5 for it in the Choose each target step.

Read more: [Microsoft: NVMe questions and answers](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-faqs)


### Linux release is not on the NVMe list

Microsoft lists the Linux releases that support NVMe disks. This machine runs a release that is not on that list. The product reads the release that the Azure Linux Agent reports. If the machine is stopped, the agent reports no release. Then the product reads the release from the image of the machine.

**This applies to v6 and v7 only. A move to v5 does not need this.**

**What to do:** To move this machine to v6 or v7, upgrade Linux to a release on the list. Then run a new assessment and plan again. Or select v5 for this machine in the Choose each target step. v5 keeps the SCSI disk controller.

Read more: [Microsoft: Linux images that support NVMe](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface)


### Windows version not tested with the product

This machine runs a Windows version older than 2016, which has PowerShell 4.0 or older. The steps the product runs inside a machine have run only on PowerShell 5.1. A move to v5 is held.

**This applies to v5 only.**

**What to do:** Keep this machine on its current size. Or upgrade Windows to Windows Server 2016 or later, or deploy it again from a newer image. Then assess it again.

Read more: [Microsoft: modernize to the v5 series](https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/sizes-v5-modernization-overview)


### Operating system disk is not a managed disk

This machine starts from an unmanaged disk in a storage account. Every step of this migration works on managed disks.

**What to do:** Convert this machine to managed disks. Then assess this machine again.

Read more: [Microsoft: convert to managed disks](https://learn.microsoft.com/en-us/azure/virtual-machines/windows/convert-unmanaged-to-managed-disks)


### Network virtual appliance

Network traffic flows through this machine. A migration stops the machine, and the traffic stops with it. The product finds an appliance from its Marketplace image or its Marketplace purchase plan, with the list in a Microsoft Azure Policy definition.

**What to do:** Deploy the new appliance beside this machine and move the traffic across. The product does not do that.

Read more: [Microsoft: appliances that stay available](https://learn.microsoft.com/en-us/azure/architecture/networking/guide/network-virtual-appliance-high-availability)


### Azure Disk Encryption is on the operating system disk

Azure Disk Encryption is not available on the v6 and v7 sizes, for Windows or Linux. Its replacement is encryption at host. A machine that has ever had Azure Disk Encryption cannot use encryption at host. Decryption does not lift that restriction, and neither does a snapshot or a disk copy.

**This applies to v6 and v7 only. A move to v5 does not need this.**

**What to do:** Choose v5 for this machine in the Choose each target step. A v5 in-place upgrade keeps Azure Disk Encryption. When the move to v5 changes the kind of temporary disk, that step does not offer v5. The product does not move an encrypted machine by the in-place upgrade (Preview). For v6 or v7, do not decrypt the machine first, because that does not make it eligible. Microsoft supports new disks and a new machine. The product does not build machines.

Read more: [Microsoft: encryption at host](https://learn.microsoft.com/en-us/azure/virtual-machines/disk-encryption)


### HPC or FPGA size (not in scope)

HPC and FPGA sizes are outside the scope of this tool, so it does not move this machine. Microsoft has its own route for these sizes.

**What to do:** Follow the retirement guide from Microsoft for this series. The End of Life list from Microsoft links the guide for each series.

Read more: [Microsoft: End of Life size series](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/end-of-life-sizes-list)


### Ls or Lsv2 size (not in scope)

Ls and Lsv2 sizes are outside the scope of this tool, so it does not move this machine. Microsoft moves them to newer L series sizes.

**What to do:** Follow the modernization guide from Microsoft. It names Lsv3, Lasv3, Lsv4 and Lasv4.

Read more: [Microsoft: modernization guide for retired sizes](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide)


### G or GS size (not in scope)

G and GS sizes are outside the scope of this tool, so it does not move this machine. Microsoft moves them to L series sizes.

**What to do:** Follow the modernization guide from Microsoft. It names Lsv3, Lasv3, Lsv4 and Lasv4.

Read more: [Microsoft: modernization guide for retired sizes](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide)


### GPU size (not in scope)

GPU sizes are outside the scope of this tool, so it does not move this machine. The GPU families are NC, ND, NG and NV.

**What to do:** Keep this machine on its GPU size. If its series is End of Life, the End of Life list from Microsoft links the guide for that series.

Read more: [Microsoft: End of Life size series](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/end-of-life-sizes-list)


### Retired size (not in scope)

Microsoft retires the size series of this machine on a date. For example, the Basic and Standard A-series retired on August 31, 2024. From one day before that date, a machine on that size is outside the scope of this tool, so it does not move this machine.

**What to do:** Resize the machine to a size that Microsoft supports, and start it. Then assess the machine again. The modernization guide from Microsoft names the sizes for each retired series.

Read more: [Microsoft: modernization guide for retired sizes](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/retirement/retired-sizes-modernization-guide)


### More than 32 data disks (not in scope)

This machine has more than 32 data disks. A machine with more than 32 data disks is outside the scope of this tool, so it does not move this machine.

**What to do:** Keep this machine on its size. To move it, detach the data disks that it does not use, until it has 32 or fewer. Then assess the machine again.

Read more: [Microsoft: sizes for virtual machines, with the data disk limit of each size](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/overview)


### SAP workload

SAP supports its software only on the sizes SAP certifies. That list is SAP Note 1928533, and it needs an SAP account to read. The product cannot read it, so it cannot say whether the new size is certified.

**What to do:** Migrate this machine the SAP way. Read SAP Note 1928533, choose a certified size, and follow the SAP guidance. The product does not move SAP machines.

Read more: [Microsoft: Azure certifications for SAP](https://learn.microsoft.com/en-us/azure/sap/workloads/certifications)


### The operating system disk is ephemeral

This machine keeps its operating system disk on the host, not in a disk resource. The disk is empty again every time the machine stops, and the product cannot copy it or move it.

**What to do:** Deploy this machine again on the new size, from whatever builds it. Nothing on an ephemeral disk is kept, so there is nothing to carry across.

Read more: [Microsoft: ephemeral operating system disks](https://learn.microsoft.com/en-us/azure/virtual-machines/ephemeral-os-disks)


### Storage or backup appliance

This machine is a storage or backup appliance from a vendor. The vendor certifies the sizes that the appliance supports. Microsoft says to treat these appliances like network virtual appliances. The product finds them from its own list of Marketplace images, which is not a Microsoft list.

**What to do:** Ask the vendor which sizes they support, and how to move the appliance. This machine is outside the scope of this tool.

Read more: [Microsoft: storage and backup virtual appliances](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/sizes-v6-v7-modernization-plan)


### Machine in an Azure managed application

An Azure managed application manages the resource group of this machine. The vendor of the application owns the machine, and the vendor certifies its sizes.

**What to do:** Ask the vendor of the managed application to change the size. This machine is outside the scope of this tool.

Read more: [Microsoft: Azure managed applications](https://learn.microsoft.com/en-us/azure/azure-resource-manager/managed-applications/overview)


### Machine with a Marketplace purchase plan

Azure records a Marketplace purchase plan on this machine. The publisher of the image sells it under that plan. Examples are Ubuntu Pro, RHEL BYOS and the SUSE offers with a name that ends in -llc. The assessment names the plan publisher, the plan product and the plan name.

**What to do:** Move this machine in the way that the publisher of the plan tells you. A machine with a purchase plan is outside the scope of this tool.

Read more: [Microsoft: Marketplace purchase plan information](https://learn.microsoft.com/en-us/azure/virtual-machines/marketplace-images)


### Failover cluster on a shared disk

A data disk of this machine is a shared disk. Its maxShares setting is more than 1, so other machines use the same disk. A migration stops this machine as if it were alone in the cluster.

**What to do:** Move the cluster one machine at a time, in the way that the cluster software tells you. This machine is outside the scope of this tool.

Read more: [Microsoft: shared disks](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-shared)


### SQL Server Always On availability group member

This machine is a member of a SQL Server Always On availability group. Its SQL virtual machine resource in Azure names the group.

**What to do:** Move the availability group one machine at a time. Fail over before you move a machine. This machine is outside the scope of this tool.

Read more: [Microsoft: availability groups for SQL Server on Azure virtual machines](https://learn.microsoft.com/en-us/azure/azure-sql/virtual-machines/windows/availability-group-overview)


### Sizes not read for this subscription

The scan could not read the list of sizes that Azure offers in the subscription and region of this machine. The scan cannot tell which sizes this machine can use.

**What to do:** Read why the list was not read under What this scan could not read. Correct the cause, then start a new assessment.

Read more: [Microsoft: Resource Skus - List](https://learn.microsoft.com/en-us/rest/api/compute/resource-skus/list)


### Facts of this machine not read

The product could not read the facts of this machine. The product cannot tell which sizes this machine can use. The other machines are not affected.

**What to do:** Read what the product said under What this scan could not read. Then start a new assessment.

Read more: [Microsoft: Azure Resource Graph](https://learn.microsoft.com/en-us/azure/governance/resource-graph/overview)

## What to check before the move

These findings do not stop the machine. A person checks the thing that each one names before the migration starts.

### SQL Server runs on this machine

This machine runs SQL Server. The migration stops the machine, and its databases are not available while it is stopped. The machine can still move.

**What to do:** Agree the downtime with the database owner before the move. Make sure that the database backups are current.

Read more: [Microsoft: SQL Server on Azure virtual machines](https://learn.microsoft.com/en-us/azure/azure-sql/virtual-machines/windows/sql-server-on-azure-vm-iaas-what-is-overview)


### This machine may be a cluster node

A fact in Azure shows that this machine may be a cluster node. Its network interface can be in a load balancer backend pool, or have more than one IP configuration. Or the machine has the SQL IaaS Agent extension. The scan cannot see inside the machine, so this is not proof. The machine can still move. Before the move, Checking runs a check inside the machine, and stops a cluster node before anything changes.

**What to do:** Ask the owner of this machine if it is a cluster node. The product does not move a cluster node, so do not put a cluster node in a wave.

Read more: [Microsoft: failover clustering](https://learn.microsoft.com/en-us/windows-server/failover-clustering/failover-clustering-overview)


### Workload type not checked

The scan could not read all the facts that find the workload type of this machine. Unknown is not the same as a standalone machine. The machine can still move.

**What to do:** Check how this machine is used before the move. Look for a cluster, a shared disk, SQL Server or a vendor appliance.

Read more: [Microsoft: workload modernization categories](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/sizes-v6-v7-modernization-discover)


### The OS disk is Standard HDD

The OS disk of this machine is a Standard HDD disk. Azure stops support for Standard HDD OS disks on 8 September 2028. On that date, Azure changes each Standard HDD OS disk to Standard SSD of the same size. The workload can stop during that change. This does not apply to a Standard HDD OS disk that Azure Site Recovery made. The machine can still move.

**What to do:** On the targets step, choose Standard SSD: OS disk. The move then changes the OS disk while the machine is stopped, and you do not stop it again later.

Read more: [Microsoft: migrate Standard HDD OS disks by 8 September 2028](https://learn.microsoft.com/en-us/azure/virtual-machines/disks-hdd-os-retirement)


### The move can download the MANA driver

The v6 and v7 sizes, and some Intel v5 and Bsv2 hosts, use the Microsoft Azure Network Adapter (MANA) for accelerated networking. When the Windows driver store of this machine has no MANA driver, the product downloads one from download.microsoft.com during the move. The scan reads Azure, so it cannot read the driver store. The machine can still move.

**What to do:** Make sure that this machine can connect to download.microsoft.com over HTTPS during the move. If the download fails, the machine stops with the reason The MANA driver could not be installed. It keeps its current size.

Read more: [Microsoft: MANA on Windows](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-windows)


### Linux release not compared with the NVMe list

Microsoft lists the Linux releases that support NVMe disks. The scan cannot compare the release of this machine with that list. The product does not read an unknown release as supported. The machine can still move.

**This applies to v6 and v7 only. A move to v5 does not need this.**

**What to do:** Start the machine. Then assess it again. Before you select v6 or v7, make sure that the machine runs a release on the list.

Read more: [Microsoft: Linux images that support NVMe](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface)


### The Linux release is past the end of standard support

The vendor of this Linux release ended its standard support. Microsoft supports accelerated networking only on releases that the vendor has not marked as end of life. The vendor can sell extended support after the end of standard support. The machine can still move.

**What to do:** Upgrade the release. Or make sure that the machine has extended support from its vendor. Before the move, Checking stops the machine. Then an approver can accept the release for this machine.

Read more: [Microsoft: accelerated networking](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-overview)


### End of support of the Linux release not known

The scan cannot compare the release of this machine with the end of standard support from its vendor. The product does not read an unknown release as supported. The machine can still move.

**What to do:** Start the machine. Then assess it again. Or read the end of standard support of the release on the page of its vendor.

Read more: [Microsoft: accelerated networking](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-overview)

## What the product will prepare

### Windows NVMe driver is not enabled

Windows starts the NVMe driver only when that driver is enabled. Without it, Windows cannot find its disks on a v6 or v7 size.

**This applies to v6 and v7 only. A move to v5 does not need this.**

**What to do:** Do nothing. The product enables the driver immediately before it stops the machine.

Read more: [Microsoft: NVMe on Azure machines](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface)


### Page file is on the temporary disk

The Windows page file sits on the temporary disk. On a v6 or v7 size that disk arrives empty, and Windows must prepare it at every start. A v5 or Bsv2 size with no temporary disk, such as D4s_v5 or B2s_v2, has no place for it.

**This applies to v6 and v7, and to a v5 or Bsv2 size with no temporary disk.**

**What to do:** Do nothing. The product moves the page file before it stops the machine.

Read more: [Microsoft: NVMe temporary disks](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-temp-faqs)


### Linux start-up image needs the NVMe driver

The Linux start-up image must load the NVMe driver. Without it, the machine cannot find its root disk after the migration.

**This applies to v6 and v7 only. A move to v5 does not need this.**

**What to do:** Do nothing. The product rebuilds the start-up image before it stops the machine.

Read more: [Microsoft: NVMe on Azure machines](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface)


### Generation is unknown

Azure reported no generation for this machine. Azure reports it for a running machine and for a stopped machine, so this is rare. Unknown is not the same as unsupported, so the product assumes nothing.

**This applies to v6 and v7 only. A move to v5 does not need this.**

**What to do:** Start this machine, then assess this machine again.

Read more: [Microsoft: Generation 2 machines](https://learn.microsoft.com/en-us/azure/virtual-machines/generation-2)


### Machine comes from a custom image

This machine comes from your own image. Azure publishes NVMe support for its own images only, so Azure has no answer about your image.

**This applies to v6 and v7 only. A move to v5 does not need this.**

**What to do:** The product does not move a machine that comes from a custom image. The support matrix in the manual lists the images that the product moves.

Read more: [Microsoft: NVMe on Azure machines](https://learn.microsoft.com/en-us/azure/virtual-machines/enable-nvme-interface)


### The kernel is checked against the MANA driver floor

The v6 and v7 sizes, and some Intel v5 and Bsv2 hosts, use the Microsoft Azure Network Adapter (MANA) for accelerated networking. Microsoft publishes a minimum kernel version for each Linux distribution, and Azure does not update this driver inside the machine. The product reads the kernel from inside this machine when it migrates, because that is the only place the version can be read.

**What to do:** Check now whether this machine's kernel meets the published minimum for its distribution, and patch it if not. Or choose Update the kernel in its Details on the Choose each target step. A machine below the floor stops before anything is changed during the migration. Without the driver, accelerated networking does not work. Nobody can accept this stop. Update the kernel, or leave the machine out.

Read more: [Microsoft: MANA on Linux, and the minimum kernel for each distribution](https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-linux)

## What the assessment records without judging

Some facts are written on the machine's record and left for the planning step, because whether they matter depends on the target size.

- **Accelerated networking.** How many network interfaces have it on. A move to v5, v6 or v7 turns it on for the primary network interface, and leaves the other interfaces as they were. Microsoft requires it on every v6 size and on the Intel D-family and E-family v5 sizes. A move never turns it off. A Linux machine whose kernel has no MANA driver does not move to a size that can give MANA. The wave settings name each machine that gets it turned on, for any reason.
- **Disk encryption.** The scan reads Azure Disk Encryption from the operating system disk, so an encrypted machine is named in the report. The setting is recorded per disk, so a machine encrypted only on its data disks does not appear here. The product asks Azure again before a move to v6 or v7 and before an in-place upgrade (Preview). A machine that has it stops before anything is changed.
- **Infrastructure code.** The assessment does not guess whether Terraform, Bicep or another tool defines a machine. You confirm once per migration that you will update your definitions afterwards.

## Workload types

Microsoft sorts workloads into patterns for the move to v6 and v7. The pattern tells you how a machine moves. The assessment gives each machine one of these types, in this order, and shows the Azure field and the value that decided it.

| Workload type | How it moves |
|---|---|
| Node pool or scale set | AKS, Azure Red Hat OpenShift or a scale set owns this machine. Add a new node pool or scale set at the new size, move the workload, then remove the old one. |
| Pooled AVD host | This machine is a session host in a pooled Azure Virtual Desktop host pool. Make new session hosts at the new size, move the users, then remove the old hosts. |
| Managed by a service | A service manages this machine: Azure Databricks or another service manages its resource group, or the machine is in an Azure CycleCloud cluster. Change the node type or the size in the service. |
| Standalone machine | You manage this machine yourself, and no fact in Azure shows another workload type. The findings of the machine, not its type, decide whether it can migrate. |
| Cluster or database | This machine holds state or is part of a cluster: SQL Server, a shared disk or SAP. Move a cluster one machine at a time, after a failover. |
| Vendor appliance | This machine is a vendor appliance. Ask the vendor which sizes they certify. Deploy a new appliance beside the old appliance, then move the traffic. |
| May be a cluster node | A fact in Azure shows that this machine may be a cluster node. Each of these is such a fact: a load balancer backend pool, more than one IP configuration, the SQL IaaS Agent extension. Before the move, Checking runs a check inside the machine and stops a cluster node. |
| Type not checked | The scan could not read all the facts that find the workload type. Check how this machine is used before the move. |

A value of **not read** in the facts means that the scan could not read that fact. Then the type is **Type not checked**, never **Standalone machine**.

## What no fact in Azure shows

The assessment cannot find these workloads, because Azure records no fact about them. Look for them yourself before you plan a wave:

- Active Directory domain controllers.
- Self-hosted build agents on single machines.
- NoSQL and search clusters, for example Cassandra, MongoDB or Elasticsearch.
- An Oracle database with Data Guard.
- Omnissa Horizon (VMware Horizon) desktops.
- Veeam or Commvault software that somebody installed on an ordinary machine, not from the vendor's image.
- Service Fabric, HDInsight and Citrix. Microsoft's pages name a fact for each, but the product does not read them.
- A machine in an Azure CycleCloud cluster that does not have the tags that CycleCloud adds, for example because somebody removed them.

A domain controller and a cluster move one machine at a time. Microsoft's page for these patterns tells you how: [Microsoft: workload modernization categories](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/lifecycle/sizes-v6-v7-modernization-discover)

<!-- next:begin -->

---

**Next:** [Checks before a machine moves](before-a-machine-moves.md)

<!-- next:end -->
