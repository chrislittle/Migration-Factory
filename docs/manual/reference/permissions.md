# What the product may do in Azure

The install creates two custom roles in your subscription. Each contains exactly the operations the product performs, listed here from the product's own map. The product holds a role only where it is granted.

The install asks what the product may do with the machines in the install subscription. Unless the answer is no access, the install grants that role on the whole subscription. An administrator grants the roles on other places on the Admin page: a management group, a subscription or a resource group. Azure allows the roles at one management group at most. The product cannot grant itself anything.

A network interface can use a subnet, a network security group, a public IP address or a load balancer in another resource group. Then grant VMF Migration there too.

## VMF Assessment

Read-only. It discovers and inspects machines so a migration can be planned. It contains nothing that can change anything, so it is safe to grant broadly.

The operations it contains, in Azure's own names, and when the product uses each one:

| Operation | When the product uses it |
|---|---|
| `Microsoft.Authorization/locks/read` | Checking reads the locks that can block the move. Backing up reads the lock of each safety copy before it puts a lock on the copy. After the daily cleanup or Delete the copies as well removes the lock of a copy, it reads the lock again. If Azure refuses to delete a rollback disk, the product reads the locks that block the delete. If a person chose to give the disk names to the new disks, Restore this machine reads the delete locks first. |
| `Microsoft.Compute/availabilitySets/read` | Checking reads the other machines in the availability set of the machine and their power state, before it changes anything. |
| `Microsoft.Compute/availabilitySets/vmSizes/read` | Checking asks Azure for the sizes that the hardware of the availability set offers, before it changes the machine. |
| `Microsoft.Compute/capacityReservationGroups/capacityReservations/read` | Reserve capacity, Release and the end of a wave read the on-demand capacity reservation of the wave. Every 5 minutes, the web service reads an on-demand capacity reservation that the product asked for and did not record. If a machine is in a capacity reservation group that this migration did not make, Checking reads the sizes that the group reserves. |
| `Microsoft.Compute/capacityReservationGroups/read` | Reserve capacity in the wave editor reads the capacity reservation group of the wave before it makes the group. |
| `Microsoft.Compute/disks/read` | Checking, Backing up, Moving and Verifying read the type, size, encryption and attachment of each managed disk. The rollback, Restore this machine, Finish the rollback and Finish the restore also read these values. An assessment, the daily cleanup, Delete these disks, Delete these disks now and Delete the copies as well also read the disks. |
| `Microsoft.Compute/locations/publishers/read` | For a machine from an Azure Marketplace image, an assessment reads the latest version of that image. The assessment uses it to find if the image supports the NVMe disk controller. |
| `Microsoft.Compute/locations/usages/read` | Check the quota, Build the waves, Reserve capacity and Start this wave read the limit and usage of each vCPU quota. The product reads every quota with this action, not with Microsoft.Quota/quotas/read. |
| `Microsoft.Compute/skus/read` | An assessment, the Choose each target step and Build the waves read the sizes and limits that Azure offers in each region. Check the quota, Reserve capacity and Start this wave also read them. Checking, the rollback and Restore this machine read them for the old size and the new size of the machine. Preparing reads them for the new size. |
| `Microsoft.Compute/snapshots/read` | Backing up and Moving read the safety copies, which are snapshots. Before the daily cleanup or Delete the copies as well deletes a safety copy, it reads the copy. After the delete, it reads the copy again to make sure that Azure deleted it. For a safety copy of a Premium SSD v2 or Ultra Disk, the rollback and Restore this machine read the copy first. |
| `Microsoft.Compute/virtualMachines/extensions/read` | Checking reads the extensions of the machine and records them. Before a move to v6 or v7, or an in-place upgrade (Preview), Checking reads them again to find Azure Disk Encryption. After the move, Verifying compares the extensions with the record from Checking. |
| `Microsoft.Compute/virtualMachines/read` | Each step of a move, a rollback or a restore reads the size, disks, settings, status and power state of the machine. An assessment reads the machines in the scan scope. Checking also reads the power state of the other machines in its availability set. Before the daily cleanup, Delete these disks or Delete these disks now deletes a disk, it reads if the machine still exists. Before a restore of an in-place upgrade (Preview), the web service reads the size of the machine. |
| `Microsoft.ContainerService/managedClusters/read` | An assessment reads the AKS clusters to find the resource groups of their machines, because the product does not move a machine that AKS manages. |
| `Microsoft.Databricks/workspaces/read` | An assessment reads the Azure Databricks workspaces to find their managed resource groups, because the product does not move those machines. |
| `Microsoft.DesktopVirtualization/hostpools/read` | An assessment lists the Azure Virtual Desktop host pools to find their session hosts, which are outside the scope of this tool. |
| `Microsoft.DesktopVirtualization/hostpools/sessionhosts/read` | An assessment lists the session hosts of each host pool, and the product does not move a machine that is a session host. |
| `Microsoft.Features/providers/features/read` | The Choose each target step reads if the preview feature VMTempDiskResizePreview is registered on the subscriptions of the machines. The wave editor reads it for each subscription that has a machine with an in-place upgrade (Preview). For an in-place upgrade (Preview) only, Checking, the rollback and Restore this machine read it again. Before a restore of an in-place upgrade (Preview), the web service reads it too. Only the in-place upgrade (Preview) needs it. The product never registers the feature. |
| `Microsoft.Management/managementGroups/read` | The step Where does the scan look? lists the management groups that the product can see, so that you can choose one. |
| `Microsoft.Management/managementGroups/subscriptions/read` | An assessment of a management group reads the subscriptions under it through Azure Resource Graph. |
| `Microsoft.Network/networkInterfaces/read` | An assessment, Checking and Verifying read each network interface of the machine and its accelerated networking setting. Moving, the rollback and Restore this machine read an interface again before they change that setting. |
| `Microsoft.Resources/subscriptions/read` | The step Where does the scan look? lists the subscriptions that the product can see. An assessment of a management group lists the subscriptions under it, to find the Azure Virtual Desktop host pools. |
| `Microsoft.Resources/subscriptions/resourceGroups/read` | The step Where does the scan look? lists the resource groups of a subscription. An assessment reads each resource group in the subscriptions of its machines, to find a group that another Azure service manages. |
| `Microsoft.SqlVirtualMachine/sqlVirtualMachines/read` | An assessment reads the SQL IaaS Agent records in the subscriptions of its machines. The product does not move a member of an Always On availability group. For another machine that runs SQL Server, the assessment shows a warning. |

## VMF Migration

Everything the assessment role can do, plus the writes a migration performs: stop, resize, snapshot, swap disks, run scripts inside the machine. Grant it as narrowly as the estate allows.

It contains every operation of the assessment role, plus these:

| Operation | When the product uses it |
|---|---|
| `Microsoft.Authorization/locks/delete` | Before the daily cleanup or Delete the copies as well deletes a safety copy, it removes the lock that the product put on it. It is optional: the product works without it, and the dashboard says when it is missing. |
| `Microsoft.Authorization/locks/write` | Backing up puts a CanNotDelete lock on each safety copy. The lock stops a delete of the copy before the retention of its wave ends. If Azure refuses to delete a copy, the daily cleanup or Delete the copies as well puts the lock back. It is optional: the product works without it, and the dashboard says when it is missing. |
| `Microsoft.Compute/capacityReservationGroups/capacityReservations/delete` | The product deletes the on-demand capacity reservation of a wave when you select Release, or when every machine of the wave has ended. Reserve capacity also deletes what it reserved when it cannot reserve the whole wave. |
| `Microsoft.Compute/capacityReservationGroups/capacityReservations/write` | Reserve capacity makes the on-demand capacity reservation of a wave, and a release sets its quantity to 0 before it deletes it. |
| `Microsoft.Compute/capacityReservationGroups/delete` | The product deletes the capacity reservation group of a wave after it deletes its on-demand capacity reservation. This happens at Release, when every machine of the wave has ended, or when Reserve capacity cannot reserve the whole wave. |
| `Microsoft.Compute/capacityReservationGroups/deploy/action` | Moving puts the machine in the capacity reservation group of the wave, and a rollback or a restore returns it to its earlier group. |
| `Microsoft.Compute/capacityReservationGroups/write` | Reserve capacity in the wave editor makes the capacity reservation group of the wave. |
| `Microsoft.Compute/diskEncryptionSets/read` | Azure checks this action only for a disk that has a disk encryption set. Azure checks it on the set when Backing up, the rollback or Restore this machine makes a copy or a disk from that disk. |
| `Microsoft.Compute/disks/beginGetAccess/action` | Azure checks this action on the safety copy when Backing up, the rollback or Restore this machine makes a managed disk from that copy. |
| `Microsoft.Compute/disks/delete` | The product deletes only the disks that it made or that a person chose to delete. The daily cleanup, Delete these disks, Delete these disks now and Delete the copies as well delete disks. Restore this machine deletes the current disks only when a person chooses to give their names to the new disks. |
| `Microsoft.Compute/disks/read` | Checking, Backing up, Moving and Verifying read the type, size, encryption and attachment of each managed disk. The rollback, Restore this machine, Finish the rollback and Finish the restore also read these values. An assessment, the daily cleanup, Delete these disks, Delete these disks now and Delete the copies as well also read the disks. |
| `Microsoft.Compute/disks/write` | Backing up makes the rollback disks from the safety copies. Moving sets the disk controller types of the OS disk, and a disk type that a person chose. The rollback and Restore this machine return each disk to its recorded disk type. If a rollback disk is not there, the rollback makes a disk from the safety copy. Restore this machine makes disks from the safety copies and sets their disk controller types. |
| `Microsoft.Compute/snapshots/delete` | The daily cleanup deletes the safety copies when the retention of the wave ends, or when a person selects Delete the copies as well. |
| `Microsoft.Compute/snapshots/read` | Backing up and Moving read the safety copies, which are snapshots. Before the daily cleanup or Delete the copies as well deletes a safety copy, it reads the copy. After the delete, it reads the copy again to make sure that Azure deleted it. For a safety copy of a Premium SSD v2 or Ultra Disk, the rollback and Restore this machine read the copy first. |
| `Microsoft.Compute/snapshots/write` | Backing up takes each safety copy, a snapshot of every disk, before anything changes and again after Shutting down. |
| `Microsoft.Compute/virtualMachines/deallocate/action` | Backing up, Shutting down, the rollback and Restore this machine stop the machine before a snapshot or a change. Finish the rollback and Finish the restore also stop the machine before they swap the data disks. If a person chose Update the kernel, Preparing stops the machine for the update. After a move, or when the run stops, the product returns the machine to the power state that Checking found. |
| `Microsoft.Compute/virtualMachines/powerOff/action` | When Checking found the machine in the power state Stopped and started it, the product returns it to Stopped after the move or a stop. |
| `Microsoft.Compute/virtualMachines/runCommand/action` | Checking, Preparing, Shutting down, Starting up and Verifying run the guest scripts of the product inside the machine with Azure Run Command. The rollback and Restore this machine run a script that checks the volumes. |
| `Microsoft.Compute/virtualMachines/start/action` | Backing up, Preparing, Starting up, the rollback and Restore this machine start the machine. Finish the rollback and Finish the restore also start the machine. If the machine is stopped, Checking starts it for the cluster check. If a person chose Update the kernel, Preparing starts the machine again after the update. If the machine was in the power state Running at Checking, the product starts it again when the run stops. |
| `Microsoft.Compute/virtualMachines/write` | Moving changes the size of the machine and, when the move needs it, its disk controller. If the wave has an on-demand capacity reservation, Moving puts the machine in its capacity reservation group. The rollback and Restore this machine return the original size, disks and capacity reservation group. Finish the rollback and Finish the restore swap the data disks. Release and the end of a wave remove each machine that the product put in the capacity reservation group. |
| `Microsoft.ManagedIdentity/userAssignedIdentities/assign/action` | Moving, the rollback, Restore this machine, Finish the rollback and Finish the restore write the machine. At each of these writes, Azure checks this action on each user-assigned managed identity of the machine. |
| `Microsoft.Network/applicationGateways/backendAddressPools/join/action` | When Moving, the rollback or Restore this machine writes a network interface, Azure checks this action on its Application Gateway backend pool. The backend pool does not change. |
| `Microsoft.Network/applicationSecurityGroups/joinIpConfiguration/action` | When Moving, the rollback or Restore this machine writes a network interface, Azure checks this action on its application security group. The application security group does not change. |
| `Microsoft.Network/loadBalancers/backendAddressPools/join/action` | When Moving, the rollback or Restore this machine writes a network interface, Azure checks this action on its load balancer backend pool. The backend pool does not change. |
| `Microsoft.Network/loadBalancers/inboundNatRules/join/action` | When Moving, the rollback or Restore this machine writes a network interface, Azure checks this action on its load balancer inbound NAT rule. The inbound NAT rule does not change. |
| `Microsoft.Network/networkInterfaces/join/action` | Moving, the rollback, Restore this machine, Finish the rollback and Finish the restore write the machine. At each of these writes, Azure checks this action on each network interface of the machine. |
| `Microsoft.Network/networkInterfaces/write` | If the accelerated networking setting of a network interface must change, Moving changes it while the machine is stopped. The rollback and Restore this machine return the setting to its recorded value. |
| `Microsoft.Network/networkSecurityGroups/join/action` | When Moving, the rollback or Restore this machine writes a network interface, Azure checks this action on its network security group. The network security group does not change. |
| `Microsoft.Network/publicIPAddresses/join/action` | When Moving, the rollback or Restore this machine writes a network interface, Azure checks this action on its public IP address. The public IP address does not change. |
| `Microsoft.Network/virtualNetworks/subnets/join/action` | When Moving, the rollback or Restore this machine writes a network interface, Azure checks this action on its subnet. The subnet does not change. |
| `Microsoft.Quota/quotaRequests/read` | After a person selects Request an increase, then Request, the product reads each quota increase request that Azure did not answer at once. It reads each one for 2 minutes, to find if Azure accepted or refused it. It is optional: the product works without it, and the dashboard says when it is missing. |
| `Microsoft.Quota/quotas/read` | No step of the product calls this action. If a quota is too low, Check the quota reads the actions that the product holds on the subscription. Request an increase needs this action and Microsoft.Quota/quotas/write. If no subscription with a low quota gives both actions, the wave editor does not show Request an increase. |
| `Microsoft.Quota/quotas/write` | The product uses this action only when a person selects Request an increase in the wave editor, then Request in the confirmation. Check the quota reads quota with Microsoft.Compute/locations/usages/read, not with this action. |

## What Restore this machine reads first

Before **Restore this machine** makes a disk or stops the machine, the product reads the permissions of its managed identity on the machine. If one of these operations is missing, the restore stops before it changes the machine:

- `Microsoft.Compute/capacityReservationGroups/deploy/action`
- `Microsoft.Compute/diskEncryptionSets/read`
- `Microsoft.Compute/disks/beginGetAccess/action`
- `Microsoft.Compute/disks/delete`
- `Microsoft.Compute/disks/read`
- `Microsoft.Compute/disks/write`
- `Microsoft.Compute/virtualMachines/deallocate/action`
- `Microsoft.Compute/virtualMachines/powerOff/action`
- `Microsoft.Compute/virtualMachines/read`
- `Microsoft.Compute/virtualMachines/start/action`
- `Microsoft.Compute/virtualMachines/write`
- `Microsoft.ManagedIdentity/userAssignedIdentities/assign/action`
- `Microsoft.Network/applicationGateways/backendAddressPools/join/action`
- `Microsoft.Network/applicationSecurityGroups/joinIpConfiguration/action`
- `Microsoft.Network/loadBalancers/backendAddressPools/join/action`
- `Microsoft.Network/loadBalancers/inboundNatRules/join/action`
- `Microsoft.Network/networkInterfaces/join/action`
- `Microsoft.Network/networkInterfaces/read`
- `Microsoft.Network/networkInterfaces/write`
- `Microsoft.Network/networkSecurityGroups/join/action`
- `Microsoft.Network/publicIPAddresses/join/action`
- `Microsoft.Network/virtualNetworks/subnets/join/action`

## What people hold

A person holds a role in the product, given on the Admin page. A person needs no right in Azure to use the product, because the service reads the migration records for them. An administrator who grants access on the Admin page needs Owner or User Access Administrator at that place.

## What the product's own identities hold

Each identity of the product, and each role it holds, is in [Security](../technical/security.md#who-is-who).

## Keys

No part of the product signs in with a password or a key. Every part signs in with an identity Azure manages, and every person signs in as themselves. Two logging settings hold a key. The service has the Application Insights connection string, and Application Insights refuses its key. The Container Apps environment has the key of the Log Analytics workspace. The Functions host of the service also makes its own host keys. It keeps them in the container `azure-webjobs-secrets`. No function of the service accepts a key. See [Security](../technical/security.md#no-secrets).

<!-- next:begin -->

---

**Next:** [Costs](costs.md)

<!-- next:end -->
