# Why a machine stopped

Every reason a machine can stop, in the words the dashboard uses. This page is generated from the product's own list, so it always matches the screen.

For each reason: what it means, what state the machine is in, what to do, and whether trying again makes sense. The machine's own panel on the migration page shows the same words. The recorded state for that machine wins over the usual state given here.
## The product's managed identity is missing a permission on this machine

Before it changes anything, the product reads its own permissions at the scope of this machine. One or more actions that the move and its rollback need are missing there. The stop names each action. The product asks first, because a permission that is missing during the move can also stop its rollback.

**The machine:** Nothing on this machine was changed.

**What to do:** Grant the VMF Migration role on this machine, its resource group or its subscription. The access Assess and migrate gives this role.

**Try again?** Correct what the entry names, then try the machine again.

## The product's managed identity cannot join a resource that a network interface links to

This move changes a network interface of this machine. Azure then checks a join permission on each resource that the network interface links to. The product's managed identity does not have it on one or more of them. The stop names each resource, its kind and the action.

**The machine:** Nothing on this machine was changed.

**What to do:** Grant the VMF Migration role on each resource that the stop names, or on its resource group. The access Assess and migrate gives this role.

**Try again?** Correct what the entry names, then try the machine again.

## The product's managed identity cannot join a network interface of this machine

The resize of this machine, and its rollback, include each network interface of the machine. Azure can check Microsoft.Network/networkInterfaces/join/action on each network interface for that. A network interface can be in a different resource group from the machine. The product's managed identity does not have the permission on one or more network interfaces. The stop names each network interface and its resource group.

**The machine:** Nothing on this machine was changed.

**What to do:** Grant the VMF Migration role on a scope that covers each network interface that the stop names. The access Assess and migrate gives this role.

**Try again?** Correct what the entry names, then try the machine again.

## The product's managed identity cannot read a disk encryption set of this machine

A disk of this machine uses a disk encryption set. Each disk that the product makes from a safety copy gets the set of the disk that it replaces. Azure checks Microsoft.Compute/diskEncryptionSets/read on the set for that. The product's managed identity does not have it on one or more sets, and the stop names each set.

**The machine:** Nothing on this machine was changed.

**What to do:** Grant the VMF Migration role on each disk encryption set that the stop names, or on its resource group. The access Assess and migrate gives this role.

**Try again?** Correct what the entry names, then try the machine again.

## The product's managed identity cannot assign a user-assigned managed identity of this machine

Each change to this machine, and its rollback, assigns its user-assigned managed identity again. Azure checks Microsoft.ManagedIdentity/userAssignedIdentities/assign/action on the identity for that. The product's managed identity does not have it on one or more identities, and the stop names each one.

**The machine:** Nothing on this machine was changed.

**What to do:** Grant the VMF Migration role or the Managed Identity Operator role on each user-assigned managed identity that the stop names. The access Assess and migrate gives the VMF Migration role.

**Try again?** Correct what the entry names, then try the machine again.

## The product's managed identity is missing a permission on the capacity reservation group of this machine

This machine is in a capacity reservation group, or was in one before the first change. The move keeps the machine in its group, and a rollback or a restore returns the machine to the group it was in. Azure checks a permission on the group for that. The product's managed identity does not have it. The stop names each group and each action.

**The machine:** Nothing on this machine was changed.

**What to do:** Grant the VMF Migration role on the capacity reservation group that the stop names. The access Assess and migrate gives this role.

**Try again?** Correct what the entry names, then try the machine again.

## Azure refused a step because the product's managed identity is missing a permission

During the move, Azure refused an action with the error AuthorizationFailed or LinkedAuthorizationFailed. The error names the action and the scope that Azure checked. LinkedAuthorizationFailed names a resource that the changed resource links to.

**The machine:** Nothing on this machine was changed.

**What to do:** Read the action and the scope in the error. Grant the VMF Migration role on that scope or on its resource group. The access Assess and migrate gives this role.

**Try again?** Correct what the entry names, then try the machine again.

## Azure has no capacity for the target size right now

The region or the availability zone cannot allocate the target size now. This is not a fault in the machine.

**The machine:** Nothing on this machine was changed.

**What to do:** Wait until Azure has capacity for the target size. An on-demand capacity reservation guarantees capacity for a wave, with a service-level agreement (SLA). Before the next wave starts, set On-demand capacity reservation for this wave to Yes, then select Reserve capacity.

**Try again?** There is nothing to correct. Try again later.

## The subscription has no more quota for the size family of the target size

Azure refused the target size, because the quota of the subscription for its size family is used up. The error names the size family. A quota does not reserve or guarantee capacity.

**The machine:** Nothing on this machine was changed.

**What to do:** Request a quota increase for the size family that the error names. Or choose a target in another size family, and plan again.

**Try again?** Correct what the entry names, then try the machine again.

## The target size does not take Premium SSD disks

Premium SSD was chosen for this machine's disks, but Azure says its target size does not take them, or does not say. A size with an s after its number, such as D4s_v5, takes them. The machine is not changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Choose a size with an s after its number, such as D4s_v5. Or keep the disk types of this machine. Then plan again.

**Try again?** Correct what the entry names, then try the machine again.

## The target size does not support a feature or a disk type that this machine uses

The target size must support encryption at host and Ultra Disk compatibility, if the machine uses them. The target size must also support Premium Storage for each Premium SSD v2 or Ultra Disk data disk. Azure says that the target size does not support one of them. If Azure does not say whether the size supports it, the machine also stops. The stop names the feature or the disk, and the size. The machine is not changed.

**The machine:** Nothing on this machine was changed.

**What to do:** To move this machine to another size, select Leave this machine out. Then assess the machines again, and plan this machine in a new migration. To keep this size, turn off the feature, or change the type of the disk that the stop names.

**Try again?** Correct what the entry names, then try the machine again.

## A disk had a type change in the last 24 hours

Azure allows two type changes for each disk in 24 hours. A move needs both of them: its own change, and the change back if the move fails. A disk of this machine had a change in the last 24 hours. The machine is not changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Wait until the time in the message. Or keep the disk types for this machine, and plan again.

**Try again?** There is nothing to correct. Try again later.

## The target size holds fewer network interfaces than this machine has

A newer size can hold fewer network interfaces than the size it replaces. For example, D2ds_v4 holds three and D2ds_v6 holds two. Checking reads the machine again, because the machine can have a new network interface since the plan.

**The machine:** Nothing on this machine was changed.

**What to do:** Choose another target for this machine on the Choose each target step, then plan again. Or remove a network interface that the machine does not use.

**Try again?** Correct what the entry names, then try the machine again.

## The capacity reservation group of this machine has no capacity reservation for the target size

This machine is in a capacity reservation group that this migration did not make. The move keeps the machine in that group. Azure resizes a machine in a group only to a size that has a capacity reservation in the group. The product found no capacity reservation for the target size in the availability zone of the machine. The stop names the group and the capacity reservations it has. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Create a capacity reservation for the target size in the group. In a zonal group, create it in the availability zone of the machine. A reserved quantity of 0 needs no more quota. Or remove the machine from the group.

**Try again?** Correct what the entry names, then try the machine again.

## This machine left its capacity reservation group after the assessment

The assessment found this machine in a capacity reservation group that this migration did not make. So the capacity reservation of its wave holds no place for it. The machine is not in that group now, and its wave is set to On-demand capacity reservation. The move would start the machine with no capacity reservation. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Add the machine to the group again. Or run a new assessment and plan again, then select Check the quota on the card Request a quota increase. Then select Reserve capacity on the wave.

**Try again?** Correct what the entry names, then try the machine again.

## The product could not read the capacity reservation group of this machine

This machine is in a capacity reservation group that this migration did not make. Before the move, the product reads the capacity reservations of the group. Azure did not give them, so the product cannot confirm a capacity reservation for the target size. The stop names the group and gives the answer of Azure. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Read the answer of Azure. If Azure refused the read, grant the VMF Assessment role on the capacity reservation group.

**Try again?** Correct what the entry names, then try the machine again.

## The target size allows accelerated networking on one network interface only

Azure allows accelerated networking on one network interface of a size with 2 vCPUs. The move turns it on for the primary network interface and keeps it on the other interfaces. After the move, more than one interface has it. Azure refuses that move after the machine stops. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Turn off accelerated networking on the other network interfaces of this machine in Azure.

**Try again?** Correct what the entry names, then try the machine again.

## The product cannot confirm that the target size allows accelerated networking on each network interface

After the move, more than one network interface of this machine can have accelerated networking. Azure allows that only on a size with more than 2 vCPUs. The product cannot confirm that the target size allows it, and the stop names the fact that it could not read. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Turn off accelerated networking on the other network interfaces of this machine in Azure. If Azure could not read a network interface, grant the VMF Assessment role on it.

**Try again?** Correct what the entry names, then try the machine again.

## Azure does not offer the target size in this machine's zone

A machine in an availability zone runs only on a size that Azure offers in that zone. Azure does not offer the target size in the zone of this machine. If Azure gives a restriction reason, the stop names it.

**The machine:** Nothing on this machine was changed.

**What to do:** Choose another target for this machine on the Choose each target step, then plan again. If the reason is NotAvailableForSubscription, you can also open an Azure support request to remove the restriction.

**Try again?** Correct what the entry names, then try the machine again.

## The hardware that hosts the availability set does not offer the target size

This machine shares an availability set with other machines. The hardware of the set does not offer the target size. Azure reports that another machine in the set has the power state Running or Starting. Azure can refuse to start this machine until every machine in the set has the power state Stopped (deallocated). The product read these facts from Azure before any change. The stop names the other machines.

**The machine:** Nothing on this machine was changed.

**What to do:** Speak to the owner of the machines in the set. Then stop each other machine in the set in Azure. Each one must have the power state Stopped (deallocated). If a machine had the power state Running before its move, it has the power state Running after the move. Stop that machine again before you try the next machine in the set.

**Try again?** Correct what the entry names, then try the machine again.

## The target size holds fewer data disks than this machine has

A newer size can hold fewer data disks than the size it replaces - E8-4ds_v5 holds 32, its v6 target holds 24.

**The machine:** Nothing on this machine was changed.

**What to do:** Choose another target for this machine on the Choose each target step, then plan again. Or detach the data disks that the machine does not use.

**Try again?** Correct what the entry names, then try the machine again.

## The original size cannot hold this machine now

A rollback or a restore returns this machine to the size it had before this product first changed it. Since then, the machine changed, and that size cannot hold it now. The stop names each limit of that size and what the machine has. Azure refuses that size while the machine is stopped. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Remove the network interfaces or data disks that the original size cannot hold. For accelerated networking, turn it off on each network interface that has it now and did not have it before.

**Try again?** Correct what the entry names, then try the machine again.

## The product cannot confirm that the original size holds this machine now

A rollback or a restore returns this machine to the size it had before this product first changed it. Since then, the machine changed. The Azure size catalog does not give a limit of that size that this change needs, and the stop names it. So the product cannot confirm that Azure accepts that size again. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Remove the network interfaces or data disks that this machine got after the first change. For accelerated networking, turn it off on each network interface that has it now and did not have it before. If Azure could not read a network interface, grant the VMF Assessment role on it.

**Try again?** Correct what the entry names, then try the machine again.

## Microsoft retires the size of this machine (not in scope)

Microsoft retires the size of this machine, and the stop names the date. From one day before that date, a machine on that size is outside the scope of this tool. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Resize this machine to a size that Microsoft supports. Then assess the machine again.

**Try again?** This machine is outside the scope of this tool. Trying again changes nothing.

## The size of this machine is not in scope

The size of this machine is in a family that is outside the scope of this tool, for example a GPU size. The stop names the size. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Leave this machine out of the run. The rest of the wave continues.

**Try again?** This machine is outside the scope of this tool. Trying again changes nothing.

## The preview feature for the in-place upgrade (Preview) is not registered

This machine takes the in-place upgrade (Preview). Azure allows this change of temporary disk only when the preview feature VMTempDiskResizePreview is registered on the subscription. Before it changed anything, the product read the feature. Azure gave a state other than Registered. The stop names the subscription and the state. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Register the preview feature VMTempDiskResizePreview on the subscription. Or choose another target for this machine on the Choose each target step, and plan again.

**Try again?** Correct what the entry names, then try the machine again.

## The product could not read the preview feature for the in-place upgrade (Preview)

This machine takes the in-place upgrade (Preview). Azure allows it only when the preview feature VMTempDiskResizePreview is registered on the subscription. Before it changed anything, the product read the feature, and Azure did not give its state. The stop names the subscription and gives the answer of Azure. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Read the answer of Azure. If Azure refused the read, grant the VMF Assessment role on the subscription. Or choose another target for this machine on the Choose each target step, and plan again.

**Try again?** Correct what the entry names, then try the machine again.

## The rollback of the in-place upgrade (Preview) needs the preview feature

This machine took the in-place upgrade (Preview), and a later step failed. The rollback changes the temporary disk again, and Azure allows that only when the preview feature VMTempDiskResizePreview is registered on the subscription. Before the rollback changed the size, the product read the feature. The feature was not registered, or the product could not read it. So the rollback did not change the size, and the machine is on its new size. It can be stopped: the failed step, or an earlier try of the same rollback, can have stopped it. The stop names the subscription and says what is known about the power state.

**The machine:** changed

**What to do:** Register the preview feature VMTempDiskResizePreview again on the subscription that the stop names. In the Azure portal, open the subscription, then Settings, then Preview features, and register it. Then use Restore this machine and choose the safety copy Before the migration. The product does not start the machine on its new size. Do not run this machine again first.

**Try again?** If you do not correct the cause first, the machine can stop again for the same reason.

## This machine has more than 32 data disks (not in scope)

This machine has more than 32 data disks, and the stop names the number. A machine with more than 32 data disks is outside the scope of this tool. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Leave this machine out of the run. The rest of the wave continues. To move it, detach the data disks that it does not use, until it has 32 or fewer. Then assess the machine again.

**Try again?** This machine is outside the scope of this tool. Trying again changes nothing.

## This machine is a cluster node (not in scope)

Before it changes a machine, the product runs a check inside it. The check found that this machine is a cluster node, in a Windows Server failover cluster or in a Pacemaker cluster on Linux. The stop names the facts that the check found. A stop of the primary cluster node causes a failover or an outage, so a cluster node is outside the scope of this tool. If the machine was not running, the product started it for the check, then stopped it again as it was. Then nothing on the machine changed. If Azure refused to stop it again, the stop says so.

**The machine:** Nothing on this machine was changed, or the machine is not in its power state from before the move. The panel of the machine says which.

**What to do:** Leave this machine out of the run. The rest of the wave continues. Move the cluster one machine at a time, in the way that the cluster software tells you.

**Try again?** This machine is outside the scope of this tool. Trying again changes nothing.

## The product could not check if this machine is a cluster node

Before it changes a machine, the product runs a check inside it that finds a cluster node. The check did not give an answer. Unknown is not the same as a machine that is alone, so the machine stopped. If Azure was still starting or stopping the machine, the product did not start it, and the check did not run. If the machine was Stopped or Stopped (deallocated), the product started it for the check, then stopped it again as it was. Then nothing on the machine changed. If Azure refused to stop it again, the stop says so. Then Try this machine again first returns the machine to its power state.

**The machine:** Nothing on this machine was changed, or the machine is not in its power state from before the move. The panel of the machine says which.

**What to do:** Make sure that the guest agent of the machine is ready. Read the reported error and clear its cause. If the stop says to wait for a power state, wait for it.

**Try again?** Correct what the entry names, then try the machine again.

## The network settings do not set the drivers of accelerated networking as unmanaged

Microsoft says that the network settings must set the drivers mana, mlx4_core and mlx5_core of accelerated networking as unmanaged devices. Accelerated networking is on after this move. Before it changes the machine, the product reads the settings of NetworkManager and systemd-networkd. The product did not find this setting. The stop names what is missing. If NetworkManager or systemd-networkd configures the virtual function of these drivers, the network of the machine can stop after the move.

**The machine:** Nothing on this machine was changed, or the machine is not in its power state from before the move. The panel of the machine says which.

**What to do:** Install azure-vm-utils version 0.6.0 or later. This package adds the udev rule from Microsoft. Or add the udev rule that the Microsoft page Accelerated Networking overview shows. If the network settings of the machine are correct, an approver accepts the move for this machine.

**Try again?** Correct what the entry names, then try the machine again.

## The product could not read the network settings for accelerated networking

Accelerated networking is on after this move. Before it changes the machine, the product reads the network settings of the machine. The product could not read if these settings set the drivers of accelerated networking as unmanaged. The product does not read an unknown answer as set. The machine stopped.

**The machine:** Nothing on this machine was changed, or the machine is not in its power state from before the move. The panel of the machine says which.

**What to do:** Check that the Azure Linux Agent of the machine has the status Ready. Read the error in the stop. Correct its cause. If the network settings of the machine are correct, an approver accepts the move for this machine.

**Try again?** Correct what the entry names, then try the machine again.

## This machine has a shared disk (not in scope)

Before it changes a machine, the product reads the maxShares setting of each data disk from Azure. A data disk of this machine has a maxShares setting of more than 1, so other machines use the same disk. The stop names the disk. A migration stops this machine as if it were alone in the cluster. A machine with a shared disk is outside the scope of this tool. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Leave this machine out of the run. The rest of the wave continues. Move the cluster one machine at a time, in the way that the cluster software tells you.

**Try again?** This machine is outside the scope of this tool. Trying again changes nothing.

## This machine is in an Azure CycleCloud cluster (not in scope)

Before it changes a machine, the product reads the tags of the machine from Azure. Azure CycleCloud adds the tags CycleCloudCluster and CycleCloudNodeArray, or ClusterId on CycleCloud 8.2 and earlier, to each machine of its clusters. The stop names the tags. CycleCloud makes and changes the machines of its cluster. A machine in a CycleCloud cluster is outside the scope of this tool. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Leave this machine out of the run. The rest of the wave continues. Change the size in the settings of the CycleCloud cluster.

**Try again?** This machine is outside the scope of this tool. Trying again changes nothing.

## This machine is on a dedicated host (not in scope)

Azure records a dedicated host or a host group on this machine. A machine on a dedicated host is outside the scope of this tool. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Leave this machine out of the run. The rest of the wave continues.

**Try again?** This machine is outside the scope of this tool. Trying again changes nothing.

## Hibernation is enabled on this machine (not in scope)

Azure records that hibernation is enabled on this machine. A machine with hibernation enabled is outside the scope of this tool. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Leave this machine out of the run. The rest of the wave continues.

**Try again?** This machine is outside the scope of this tool. Trying again changes nothing.

## This machine is a storage or backup appliance (not in scope)

Before it changes a machine, the product reads the image and the Marketplace plan of the machine from Azure. They show that this machine is a storage or backup appliance from a vendor. The stop names the vendor and the Azure fields. The vendor certifies the sizes that the appliance supports. The product finds appliances from its own list of Marketplace images, which is not a Microsoft list. An appliance is outside the scope of this tool. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Leave this machine out of the run. The rest of the wave continues. Ask the vendor which sizes they support, and how to move the appliance.

**Try again?** This machine is outside the scope of this tool. Trying again changes nothing.

## This machine is a network virtual appliance (not in scope)

Before it changes a machine, the product reads the image and the Marketplace purchase plan of the machine from Azure. They show that this machine is a network virtual appliance, such as a firewall. The stop names the Azure fields: imageReference.publisher and imageReference.offer, or plan.publisher and plan.product. Network traffic goes through this machine. When a migration stops the machine, the traffic stops too. The product finds an appliance with the list in a Microsoft Azure Policy definition. An appliance is outside the scope of this tool. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Leave this machine out of the run. The rest of the wave continues. Deploy the new appliance beside this machine and move the traffic across.

**Try again?** This machine is outside the scope of this tool. Trying again changes nothing.

## This machine has a Marketplace purchase plan (not in scope)

Before it changes a machine, the product reads the Marketplace purchase plan of the machine and of its OS disk from Azure. This machine has a plan. The stop names the Azure fields plan.publisher, plan.product and plan.name. The publisher of the image sells it under that plan. Examples are Ubuntu Pro, RHEL BYOS and the SUSE offers with a name that ends in -llc. A machine with a purchase plan is outside the scope of this tool. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Leave this machine out of the run. The rest of the wave continues. Move this machine in the way that the publisher of the plan tells you.

**Try again?** This machine is outside the scope of this tool. Trying again changes nothing.

## The kernel version is below the minimum that Microsoft lists for MANA

The v6 and v7 sizes, and some Intel v5 and Bsv2 hosts, use the Microsoft Azure Network Adapter (MANA) for accelerated networking. MANA has a published minimum kernel version for each Linux distribution. Azure does not update this driver inside the machine. Without the driver, accelerated networking does not work after the move, so a machine below that version stops before anything is changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Choose Update the kernel for this machine on the Choose each target step, then plan again. Or patch the machine to a supported kernel and restart it. If neither is possible, leave the machine out of this migration.

**Try again?** Correct what the entry names, then try the machine again.

## The target size requires accelerated networking

Microsoft requires accelerated networking on every v6 size and on the Intel D-family and E-family v5 sizes. The product also keeps it on for every size that can give the MANA adapter: v7, Intel v5 and Bsv2. It is off on this machine, and the plan keeps it off.

**The machine:** Nothing on this machine was changed.

**What to do:** An approver accepts accelerated networking for this machine, and the move turns it on before the resize. Or choose a different target for this machine in the Choose each target step, then plan again.

**Your decision:** An approver accepts this for this machine, or the machine leaves the run. Trying again changes nothing.

## The vendor ended standard support for this Linux release

The vendor of this Linux release ended its standard support. The stop names the vendor, the release and the date. Microsoft supports accelerated networking only on releases that the vendor has not marked as end of life. The vendor can sell extended support after the end of standard support.

**The machine:** Nothing on this machine was changed.

**What to do:** Upgrade the release. Then run a new assessment. Select Delete this migration on the Migrations page. Then plan a new migration from the assessment. If the machine has extended support from its vendor, an approver can accept the release for this machine.

**Your decision:** An approver accepts this for this machine, or the machine leaves the run. Trying again changes nothing.

## There is data on the temporary disk that would be lost

The temporary disk does not survive this migration - it is re-created empty on the new size. Files were found on it that are not the standard system files, so the run stopped rather than discard them.

**The machine:** Nothing on this machine was changed.

**What to do:** Move the listed files somewhere permanent. The temporary disk does not survive the move, so files left on it are lost. If nothing needs them, an approver accepts the loss for this machine instead.

**Try again?** Correct what the entry names, then try the machine again.

## Azure Disk Encryption is enabled on this machine

Azure Disk Encryption is not available on the v6 and v7 sizes, for Windows or Linux. Its replacement is encryption at host. A machine that has ever had Azure Disk Encryption cannot use encryption at host. Decryption does not lift that restriction, and neither does a snapshot or a disk copy. A v5 in-place upgrade keeps Azure Disk Encryption. So on v5 this stop comes only before an in-place upgrade (Preview), which changes the kind of temporary disk. The product does not make this change on a machine with Azure Disk Encryption.

**The machine:** Nothing on this machine was changed.

**What to do:** Do not decrypt this machine, because that does not make it eligible. In the Choose each target step, choose a v5 size with the same kind of temporary disk, then plan again.

**Try again?** Correct what the entry names, then try the machine again.

## A ReadOnly lock blocks every change to this machine

A ReadOnly lock covers this machine, its resource group or its subscription. Azure refuses every change under a ReadOnly lock, so the product cannot stop or resize the machine. The stop names each lock and its scope.

**The machine:** Nothing on this machine was changed.

**What to do:** Remove each lock that the stop names for the change window.

**Try again?** Correct what the entry names, then try the machine again.

## A resource lock blocked a change of this move

During the move, Azure refused a change with the error ScopeLocked. A lock covers the resource, its resource group or its subscription. The error names the scope of the lock. It does not give the type of the lock.

**The machine:** Nothing on this machine was changed.

**What to do:** Find the lock on the scope that the error names, on its resource group or on its subscription. Remove it for the change window.

**Try again?** Correct what the entry names, then try the machine again.

## Azure refused a change because the subscription of this machine is read only

Azure refused a change with the error ReadOnlyDisabledSubscription. Microsoft says that this error means that the subscription is disabled.

**The machine:** Nothing on this machine was changed.

**What to do:** Reactivate the subscription, as the Microsoft page Reactivate a disabled Azure subscription tells you.

**Try again?** Correct what the entry names, then try the machine again.

## A preparation step inside the machine could not complete

A script that runs inside the machine reported that it could not finish. The stop gives the message of the script, which says why. If the script changed the machine before it stopped, the product rolled the machine back from the first safety copy.

**The machine:** Nothing was changed, or the product rolled the machine back. The panel of the machine says which.

**What to do:** Read the reported error and clear the cause inside the machine.

**Try again?** Correct what the entry names, then try the machine again.

## The MANA driver could not be installed

The target size can use the Microsoft Azure Network Adapter (MANA), and the Windows driver store on this machine has no MANA driver. The product downloads one MANA driver version from Microsoft and checks its checksum. It also checks that Microsoft signed each driver file in it. Then it adds the driver to the driver store. That did not complete. Without the driver, the machine stops before the size changes. If the install added files before it stopped, the product rolled the machine back from the first safety copy.

**The machine:** Nothing was changed, or the product rolled the machine back. The panel of the machine says which.

**What to do:** Read the reported error. Install the MANA driver from the Microsoft download yourself, or let the machine connect to download.microsoft.com. When the error is about the checksum or about a signature from Microsoft, install the driver yourself.

**Try again?** Correct what the entry names, then try the machine again.

## The kernel update did not give the machine a MANA driver

A person chose to update the kernel of this Linux machine during the move. The product updated the kernel with the package manager of the distribution, then stopped and started the machine. The update failed, the machine did not start again, or the kernel still has no MANA driver. The product rolled the machine back from the first safety copy, so it runs on its old kernel. If the rollback did not finish, the panel of the machine says so.

**The machine:** The machine was rolled back to how it was.

**What to do:** Read the reported error and the kernel versions. Update the kernel yourself with the package manager of the distribution, and make sure that the machine starts on it. For an AMD machine, you can choose AMD v5 instead.

**Try again?** Correct what the entry names, then try the machine again.

## The repositories of this machine have no newer kernel

A person chose to update the kernel of this Linux machine during the move. The product asked the package manager of the distribution for a kernel newer than the running kernel. The repositories that the machine uses have no newer kernel. So the kernel still has no MANA driver, or it is older than the minimum that Microsoft lists. Nothing on the machine was changed. Microsoft says that a Red Hat Enterprise Linux pay-as-you-go image for one minor release, such as RedHat:RHEL:94_gen2, uses the Extended Update Support (EUS) repositories. These repositories stay on that minor release, so an update does not get the kernel of a later minor release.

**The machine:** Nothing on this machine was changed.

**What to do:** Make a newer kernel available to this machine. If the machine uses the Red Hat EUS repositories, move it to the RHEL release that Microsoft lists for MANA. It can use EUS or non-EUS repositories. The Microsoft page Red Hat Update Infrastructure gives the steps. For an AMD machine, you can choose an AMD v5 size on the Choose each target step, then plan again. AMD v5 does not use MANA. If neither is possible, leave the machine out of this migration.

**Try again?** Correct what the entry names, then try the machine again.

## The product cannot update this kernel

The product updates only the Azure kernel. On Ubuntu, the Azure kernel is linux-azure. This machine runs a different kernel. Update the kernel cannot change this kernel. The product did not change the machine.

**The machine:** Nothing on this machine was changed.

**What to do:** Install a kernel with a MANA driver. For an AMD machine, you can choose AMD v5 instead. Or leave the machine out.

**Try again?** Correct what the entry names, then try the machine again.

## An update cannot reach the kernel version that Microsoft lists for MANA

The kernel is below the minimum version that Microsoft lists for MANA. On this machine, an update cannot install a kernel at that version. The cause is the repositories, the kernel flavour or the releasever setting. The product did not change the machine. The stop names the cause.

**The machine:** Nothing on this machine was changed.

**What to do:** Read the cause in the stop. Install a kernel at the minimum version with the steps from the maker of the distribution. For an AMD machine, you can choose an AMD v5 size on the Choose each target step, then plan again. AMD v5 does not use MANA. Or leave the machine out.

**Try again?** Correct what the entry names, then try the machine again.

## Microsoft does not list this Linux release for MANA

A kernel update does not change the release, so the product did not update the kernel.

**The machine:** Nothing on this machine was changed.

**What to do:** Upgrade to the release that the stop names. For an AMD machine, you can choose AMD v5 instead. Or leave the machine out.

**Try again?** Correct what the entry names, then try the machine again.

## Microsoft does not list this UEK kernel for MANA

Microsoft lists UEK R8 for MANA, and not this UEK kernel. The product installs UEK R8 only when the UEK R8 repository of the release is enabled on the machine. The product does not change repositories. The stop says why the product did not update the kernel.

**The machine:** Nothing on this machine was changed.

**What to do:** Do what the stop says, with the steps from Oracle. For an AMD machine, you can choose AMD v5 instead. Or leave the machine out.

**Try again?** Correct what the entry names, then try the machine again.

## The machine could not be shut down

Azure did not complete the shutdown. If the preparation had changed the machine, the product rolled it back from the first safety copy. If the rollback could not shut the machine down either, the machine keeps the preparation. If the preparation did not change the machine, the product returned it to the power state that it had before the move. If the machine was running before the move, or the product has no record of its power state, the product started it again. If the machine was not running before the move, the product stopped it again, in the same power state that it had. Then nothing on the machine changed. If the product could not start it or stop it again, the stop says so. The panel then says that the machine is not as it was.

**The machine:** Nothing was changed, the product rolled the machine back, or the machine is not in its power state from before the move. The panel of the machine says which.

**What to do:** Read the error from Azure. Look for a lock or another operation on the machine. If the panel says that more than the power state is not as it was, use Restore this machine first.

**Try again?** Correct what the entry names, then try the machine again.

## The plan holds a setting value that this product does not know

The plan for this machine holds a wave setting value that this version of the product does not write. So the product did not change the machine.

**The machine:** Nothing on this machine was changed.

**What to do:** Select Leave this machine out. Then plan it again in a new migration, and set the wave settings again.

**Try again?** This version of the product cannot migrate this machine.

## The machine did not start on its new size

The size changed, but the machine did not start. Before the rollback, the product reads the boot diagnostics of the machine when Azure gives them. Then the product rolled the machine back to its original size, with its disks from the first safety copy.

**The machine:** The machine was rolled back to how it was.

**What to do:** Read the error and the boot diagnostics of the machine, and correct the cause.

**Try again?** Correct what the entry names, then try the machine again.

## The machine started but did not pass its health checks

The machine started on its new size. One of the checks the run makes afterwards did not pass, and the stop names that check. The product rolled the machine back to how it was.

**The machine:** The machine was rolled back to how it was.

**What to do:** Read which check failed, and correct that cause.

**Try again?** Correct what the entry names, then try the machine again.

## Something failed, and the machine was rolled back

A step failed after the product had changed the machine. The product rolled the machine back. It uses the copy it took before it started, on the original size and controller.

**The machine:** The machine was rolled back to how it was.

**What to do:** Read what failed, and correct the cause.

**Try again?** Correct what the entry names, then try the machine again.

## Something failed, and the rollback also failed

The rollback did not finish, so the machine is not as it was. Its safety copies and its old disks still exist.

**The machine:** changed

**What to do:** Read both error messages first. Then use Restore this machine and choose the safety copy Before the migration. Do not run this machine again first.

**Try again?** If you do not correct the cause first, the machine can stop again for the same reason.

## After the rollback, Azure has no capacity to start the machine on its original size

After a step failed, the product rolled the machine back to its original size. Every disk is back from the first safety copy. Azure has no capacity for the original size now, so the machine did not start. The product tried to start the machine 4 times in about 6 minutes. Microsoft restricts capacity growth for older size series. The product does not guarantee capacity.

**The machine:** The machine is rolled back and stopped.

**What to do:** When Azure has capacity for the original size again, start the machine. Or select Change to v5. A move to v5 changes the size first, and then starts the machine. If a Windows machine needs a change inside it before the move, it must run on its original size first.

**Try again?** There is nothing to correct. Try again later.

## The rollback stopped because Azure refused the original size

A step failed after the move changed the size. Azure refused the original size when the rollback tried to set it again, for example with NotAvailableForSubscription. The rollback did not swap a disk. The machine is stopped on its new size. Its disks are as the move left them. The stop names each setting that the rollback restored before the size change. Its safety copies and the disks that the rollback made still exist.

**The machine:** changed

**What to do:** Read the error from Azure. If Azure restricts the size for your subscription, open an Azure support request to remove the restriction. Then use Restore this machine, and choose the safety copy Before the migration. Or select Change to v5. Then use Restore this machine, and choose the safety copy Before the migration. The restore changes the machine to the v5 size. Then accept the wave settings, get the sign-off again, and select Try this machine again.

**Try again?** If you do not correct the cause first, the machine can stop again for the same reason.

## Azure did not swap a data disk back

The rollback put the disks back from the first safety copy. Azure refused to swap one or more data disks, also when the product tried again. Or a swap stopped between its two changes, and Azure did not attach the disk made from the copy to the empty LUN. So the machine is stopped, and it does not start with disks from two moments. The error names each disk that is back and each disk that is not.

**The machine:** changed

**What to do:** Read the error first. Then use Finish the rollback on this machine. It swaps only the data disks that are left, then starts the machine. Do not run this machine again first.

**Try again?** If you do not correct the cause first, the machine can stop again for the same reason.

## A step failed several times in a row

The product tried the step the maximum number of times, and each try failed. The product already sends a request again after a temporary Azure error.

**The machine:** Nothing on this machine was changed.

**What to do:** Read the reported error. If it names something you can correct, correct it and try again.

**Try again?** If you do not correct the cause first, the machine can stop again for the same reason.

## A safety copy is missing, so the machine was not changed

The product checks that the safety copies of this machine still exist before it changes anything. One of them is gone. The product locks each copy when it takes it, if its identity has the right to place locks. A person or a process with the rights to do so deleted the copy. The machine is untouched.

**The machine:** Nothing on this machine was changed.

**What to do:** The product takes new copies before it changes anything. Find who deleted the copy, and why.

**Try again?** Correct what the entry names, then try the machine again.

## Azure is still filling a Premium SSD v2 or Ultra Disk data disk from a copy

A data disk of this machine is on Premium SSD v2 or Ultra Disk, and Azure is still copying data into it from a snapshot. This occurs soon after a rollback or a restore made the disk. Azure takes no instant access copy of such a disk, and the product needs that copy to roll the disk back. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Wait until Azure finishes filling the disk. The stop names each disk and how much of it is filled.

**Try again?** There is nothing to correct. Try again later.

## Azure could not use a safety copy in time, so the machine did not move

The first safety copy of each Premium SSD v2 and Ultra Disk data disk is an instant access snapshot. The product changes the machine only when Azure can make a disk from every copy. Azure did not make a copy usable within 30 minutes, and the machine stayed stopped during that time. The product never waits while the machine runs. If the machine was running before the move, or the product has no record of its power state, the product started it again. If the machine was not running before the move, the product stopped it again, in the same power state that it had. Then nothing on the machine changed. If the product could not start it or stop it again, the stop says so. The panel then says that the machine is not as it was.

**The machine:** Nothing on this machine was changed, or the machine is not in its power state from before the move. The panel of the machine says which.

**What to do:** The stop names each copy and its access state in Azure. The next attempt takes new copies of every disk.

**Try again?** There is nothing to correct. Try again later.

## This machine is in an availability set and has a Premium SSD v2 or Ultra Disk data disk (not in scope)

This machine is in an availability set, and a data disk of it is on Premium SSD v2 or Ultra Disk. Azure does not attach such a disk across fault domains while it has an instant access snapshot. A rollback of this machine could then not attach its disks. A machine like this is outside the scope of this tool. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Leave this machine out of the run. The rest of the wave continues. The stop names each data disk of these types.

**Try again?** This machine is outside the scope of this tool. Trying again changes nothing.

## Azure did not return a value that a rollback needs for a Premium SSD v2 or Ultra Disk data disk

A rollback makes each Premium SSD v2 and Ultra Disk data disk again with its IOPS, throughput and sector size. Azure did not return one of these values for a data disk of this machine. The product does not start a move that it cannot roll back. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Open each named disk in the Azure portal, and make sure that its performance settings show. If a value stays missing, leave this machine out of the run.

**Try again?** Correct what the entry names, then try the machine again.

## The product could not read the encryption of a disk exactly

A rollback makes each disk again from its safety copy, with the encryption type and disk encryption set of the current disk. Azure did not return these for a disk of this machine, or returned values that the product does not know. The product does not start a move that it cannot roll back fully. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Open each named disk in the Azure portal, and look at its encryption. If Azure does not show it, leave this machine out of the run.

**Try again?** Correct what the entry names, then try the machine again.

## The product could not read the disk type or the size of a disk

A rollback makes each disk again from its safety copy, with the disk type of the current disk. The product could not read the disk type or the size of a disk of this machine. The reason names each disk and what Azure said. The product does not start a move that it cannot roll back fully. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Read what Azure said for each named disk. If Azure refused the read, grant the VMF Assessment role on the disk. If Azure returned no value, open the disk in the Azure portal, and look at its type and size. If they do not show, leave this machine out of the run.

**Try again?** Correct what the entry names, then try the machine again.

## The product could not read a permission on a user-assigned managed identity

Each change to this machine, and its rollback, assigns its user-assigned managed identity again. Azure checks a permission on the identity for that. The product could not read its own permissions on the identity, or Azure did not return the identity. Without that permission, the move and its rollback both fail, so the product does not start the move. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Make sure that each named managed identity exists and that Azure shows it.

**Try again?** Correct what the entry names, then try the machine again.

## The product could not read a permission on a network interface of this machine

The resize of this machine, and its rollback, include each network interface of the machine. Azure can check a permission on each network interface for that. The product could not read its own permissions on a network interface, or Azure did not return the id of a network interface. If Azure refuses the permission while the machine is stopped, the machine can stay stopped, so the product does not start the move. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Make sure that each named network interface exists and that Azure shows it.

**Try again?** Correct what the entry names, then try the machine again.

## The product could not make the rollback disks, so the machine did not move

Before the move changes anything, the product makes a disk from each first safety copy, so that a rollback only puts disks on the machine. Azure did not make one of these disks, or made a disk that differs from the record. The product deletes the disks it made, and the stop names each disk that it could not delete. The product stopped the move before it changed the machine.

**The machine:** Nothing on this machine was changed, or the machine is not in its power state from before the move. The panel of the machine says which.

**What to do:** The stop names the disk and what Azure said. Correct that cause. The next attempt takes new copies and makes the disks again.

**Try again?** Correct what the entry names, then try the machine again.

## The product could not return the machine to its power state, so the move did not start again

The product could not return the machine to the power state that it had earlier: Stopped (deallocated) or Stopped. When you try the machine again, the product first returns it to that power state. Azure refused this at each try, so the product did not start the move again. Nothing else on the machine changed. The machine can be running now.

**The machine:** changed

**What to do:** The stop says what Azure said. Correct that cause, for example a lock or another operation on the machine.

**Try again?** Correct what the entry names, then try the machine again.

## A safety copy would not last through the move, so the machine did not move

Just before the move, the product checks the first safety copy of each Premium SSD v2 and Ultra Disk data disk. Each copy must be complete, or usable for 120 more minutes. One copy was not, so a rollback during the move could fail. If the preparation had changed the machine, the product rolled it back from the first safety copy. If the preparation did not change the machine, the product returned it to the power state that it had before the move. If the machine was running before the move, or the product has no record of its power state, the product started it again. If the machine was not running before the move, the product stopped it again, in the same power state that it had. Then nothing on the machine changed. If the product could not start it or stop it again, the stop says so. The panel then says that the machine is not as it was.

**The machine:** Nothing was changed, the product rolled the machine back, or the machine is not in its power state from before the move. The panel of the machine says which.

**What to do:** The stop names each copy and the minutes of instant access that it had left. The next attempt takes new copies of every disk.

**Try again?** There is nothing to correct. Try again later.

## A storage volume the machine had before the move is missing after it

After the move, a check inside the machine did not find a volume that was mounted before the move. Or it found that an LVM volume group on Linux, or a Storage Spaces pool on Windows, is not complete. The operating system started, and only that volume is missing. The product rolled the machine back to its original size and disks. The stop names the volume.

**The machine:** The machine was rolled back to how it was.

**What to do:** Find which disks the volume uses, and make sure that each one is attached to this machine. Check the volume inside the machine.

**Try again?** Correct what the entry names, then try the machine again.

## A volume is not mounted after the rollback or the restore

The product put the disks back from a safety copy and started the machine. Then a check inside the machine found that a volume that was mounted before the move is not mounted now. On Linux, the product first made LVM find its disks on their new device IDs. So the machine is not as it was. The stop names each volume.

**The machine:** changed

**What to do:** Mount the volume inside the machine, then select Try this machine again. The product first checks that every volume mounted before the move is mounted again.

**Try again?** If you do not correct the cause first, the machine can stop again for the same reason.

## The product could not check the volumes inside the machine

After a rollback or a restore, a check found a volume that is not mounted, or the check could not run. The product must check the volumes again before it tries the machine again. This time, the check could not run inside the machine. The stop says why. The product does not know if every volume is mounted. The record keeps the machine as changed.

**The machine:** changed

**What to do:** Correct the cause that the stop names. Make sure that every volume that was mounted before the move is mounted. Then select Try this machine again, or select Check the volumes.

**Try again?** If you do not correct the cause first, the machine can stop again for the same reason.

## The product cannot reach the subscription of this machine

Before it changes a machine, the product changes to the subscription of the machine. Azure refused that change, or the resource ID of the machine does not name a subscription. Without that change, an action could reach a different machine with the same name. The stop gives the answer of Azure. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** On the Admin page, give Assess and migrate on the subscription of this machine, or on a scope above it. If the subscription no longer exists, select Leave this machine out.

**Try again?** Correct what the entry names, then try the machine again.

## Azure did not say if this machine has Azure Disk Encryption

Azure Disk Encryption is not available on the v6 and v7 sizes. So the product checks for it before a move to v6 or v7. It also checks before an in-place upgrade (Preview), which changes the kind of temporary disk. The Azure Disk Encryption setting of a disk has no value. Unknown is not the same as no encryption, so the machine stopped. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Look at the machine in the Azure portal, and see if Azure Disk Encryption is on. If it is on, this machine cannot move to v6 or v7, or by an in-place upgrade (Preview). Decryption does not change that.

**Try again?** Correct what the entry names, then try the machine again.

## Azure did not return the extensions of this machine

Before it changes a machine, the product reads the extensions of the machine from Azure. The check after the move compares the extensions with this list, so a move that loses an extension fails. Azure did not answer the read, and the product tried it again. Unknown is not the same as a machine with no extensions, so the machine stopped. Nothing on the machine was changed.

**The machine:** Nothing on this machine was changed.

**What to do:** Open the machine in the Azure portal, and make sure that its extensions show. Read the reported error and clear its cause.

**Try again?** Correct what the entry names, then try the machine again.

## This machine never finished, so it was stopped

The steps passed this machine between one another and never reached an end. The product stopped the machine and marked it for attention. If the preparation had changed the machine, the product rolled it back from the first safety copy. This is a fault in the product, not in the machine.

**The machine:** changed

**What to do:** Read this machine's history to see which steps repeated. Report the loop as a fault. The disks and the copy taken before the run both still exist. The history also gives the power state of the machine.

**Try again?** If you do not correct the cause first, the machine can stop again for the same reason.

<!-- next:begin -->

---

**Next:** [Wave settings](wave-settings.md)

<!-- next:end -->
