# Security and permissions questions

## Which identities does the product have, and which roles do they hold?

The product has three managed identities. The service has a system-assigned managed identity. The engine and the publish job each have a user-assigned managed identity. People sign in with their work accounts, and hold only a role in the product.

The install gives each identity the roles that it needs in the product's resource group. The engine holds VMF Assessment or VMF Migration where the install or an administrator grants access. The service holds VMF Assessment at the same places, and never VMF Migration.

Each identity and each role it holds: [Security](security.md#who-is-who). The data roles on each container of the run store: [The run store](run-store.md#who-may-read-and-write).

## Does the product store a secret, a key or a password?

No part of the product signs in with a password or a key. The storage account refuses its access keys, and Application Insights refuses its instrumentation key. Two logging settings hold a key: see [Security](security.md#no-secrets).

The Functions host of the service makes its own host keys. It keeps them in the container `azure-webjobs-secrets` of the storage account. Only the service holds a data role on that container. No function of the service accepts a key. A user with a role such as Owner or Contributor on the service can read the host keys in Azure. See [Security](security.md#no-secrets).

## Why does VMF Migration hold delete, Run Command and quota actions?

Each action is in the role because the code uses it. A test fails the build when the code uses an action that the role does not hold.

| Action | When the product uses it |
|---|---|
| Delete a virtual machine | Never. The roles do not hold `Microsoft.Compute/virtualMachines/delete`. No move, rollback or restore deletes or creates a machine. |
| Write an extension | Never. The roles hold only `Microsoft.Compute/virtualMachines/extensions/read`. The product reads the extensions to find Azure Disk Encryption, and to check that each extension is healthy after the move. |
| `Microsoft.Compute/disks/delete` | To delete a managed disk that the product made, or a disk that a person chose to delete. See [When the product deletes a disk or a snapshot](#when-the-product-deletes-a-disk-or-a-snapshot). |
| `Microsoft.Compute/snapshots/delete` | To delete the safety copies. See [When the product deletes a disk or a snapshot](#when-the-product-deletes-a-disk-or-a-snapshot). |
| `Microsoft.Compute/virtualMachines/runCommand/action` | The engine runs the product's own guest scripts to prepare and verify the machine. |
| `Microsoft.Quota/quotas/write` | Only when a person selects **Request an increase** on a wave, then **Request** in the confirmation. |
| `Microsoft.Quota/quotaRequests/read` | Only after the product files a quota increase request, to read the answer of Azure for up to 2 minutes. The action is optional. Without it, the page says that the product could not read the answer. |
| The capacity reservation group actions | To make the on-demand capacity reservation of a wave, and to release it. To keep a machine in its capacity reservation group. |
| `Microsoft.Authorization/locks/write` and `locks/delete` | The engine locks each safety copy, and removes its own lock when the retention ends. Both are optional. |

Every action in the two roles: [What the product may do in Azure](../reference/permissions.md). The safety copies and the rollback disks: [Safety copies and rollback](../understand/safety-copies.md). A quota request: [Capacity and quota](../use/capacity.md#request-a-quota-increase).

### When the product deletes a disk or a snapshot

The product deletes a safety copy, which is a snapshot, at these times:

- The daily cleanup deletes the safety copies of a migrated machine when the retention of its wave ends.
- A person deletes a migration and selects **Delete the copies as well**.

The product deletes a managed disk at these times:

- When the move is complete, it deletes the rollback disks that no rollback used.
- When Azure makes a rollback disk that is not correct, the move stops, and the product deletes the disks that it made.
- A restore deletes the temporary disk that it made, when it no longer needs it.
- The daily cleanup deletes each disk that the product made and nothing uses, after the move of the machine ended.
- A person selects **Delete these disks** or **Delete these disks now** on the panel of a machine.
- A person deletes a migration and selects **Delete the copies as well**. The product deletes each disk made from the copies that no machine uses.
- For a restore, a person selects **No. Delete them, and give the new disks their names**. The product deletes the current disks.

## Why does the role hold network join actions?

On a stopped machine, the product sets accelerated networking on the network interface. On each write of a network interface, Azure checks a join action on each resource that the interface links to. These are the subnet, the network security group, the public IP address and the application security groups. They are also the pools and inbound NAT rules of a load balancer, and the pools of an Application Gateway.

The product does not change these resources. The join actions only let Azure accept the write of the network interface with its links as they are. Before any change, the product reads these permissions on each linked resource. When one is missing, the move stops before any change. **Restore this machine** also reads these permissions before any change. If one is missing, the restore stops. See [Why a machine stopped](../reference/stop-reasons.md) and [Restore a machine](../use/put-back.md#when-the-restore-stops).

## Can the product run a script inside a machine?

It runs only its own guest scripts, through Azure Run Command. The product keeps a list of its guest scripts with the SHA-256 hash of each. Before each run, the engine compares the script with its hash. When they are different, the engine does not run the script.

On Windows, when the driver store has no MANA driver, a script downloads one pinned driver package from Microsoft. It installs the package only when the SHA-256 hash matches and Microsoft signed each driver file. On Linux, the product updates the kernel only when a person chose **Update the kernel** for that machine. On a Red Hat Enterprise Linux pay-as-you-go machine, the product first updates the RHUI client package from the Microsoft repository. See [How a machine moves](../understand/how-a-machine-moves.md).

## Does a move delete a machine or its system-assigned identity?

No. Every move is the in-place upgrade or the in-place upgrade (Preview): the product stops the machine, changes it and starts it again. No rollback and no restore rebuilds a machine. So the system-assigned identity keeps its object ID, and its role assignments stay in place.

The Verifying step checks the identity. A system-assigned identity with a new object ID fails the step, and the engine rolls the machine back. See [How a machine moves, in detail](machine-state-machine.md). The product does not find, or give again, the access of a managed identity. See [Security](security.md#what-the-product-does-not-look-at).

## What is the smallest place for each role?

The smallest place that the Admin page offers is one resource group. Give **Assess** broadly, and give **Assess and migrate** only on the resource groups that hold the machines of a wave. See [The Admin page](../use/admin.md#where-the-product-may-work).

A machine can use resources in another resource group. These are the resources that a network interface links to, a user-assigned managed identity, a disk encryption set and a capacity reservation group. Grant VMF Migration on each of them, or on its resource group. Before any change, the product reads its permissions on each resource, and the stop names each missing one.

With the roles on one resource group, the product read the preview feature and moved a machine with the in-place upgrade (Preview). A rollback reads the feature again, and that read is not tested on such a grant. If Azure refuses the read, the stop says to grant VMF Assessment on the subscription.

## Can I grant the assessment role at a management group?

Yes. On the Admin page, choose **A management group**. The grant applies to every subscription under it, also to subscriptions added later. To grant at a management group, you need rights above a subscription.

Azure lets a custom role name one management group at most. So the two roles of the product can reach only one management group. For a second one, grant at a management group that holds both, or install the product again. See [The Admin page](../use/admin.md#where-the-product-may-work).

## What data does the product keep, and who can read it?

The run store is a storage account in the product's resource group. It keeps the plans, the state of each machine and each approval with the name of the person. It also keeps the activity log and the output of each guest script. The safety copies are snapshots in your own resource groups.

| Data | How long it stays | Who can read it |
|---|---|---|
| The records of a migration or an assessment | Until a person deletes it on the dashboard, or removes the product | The service and the engine. A person with a role reads them through the service. |
| The kept record of each migration | 90 days, also after a person deletes the migration | The service and the engine. An administrator downloads it through the service. |
| The logs of the engine | The install sets the Log Analytics workspace of the product to keep data 30 days. | A person with an Azure role on the workspace |
| The telemetry of the service | The Log Analytics workspace of the product keeps the tables of Application Insights 90 days. Microsoft sets 90 days on these tables by default. The install also sets 90 days on the Application Insights resource. | A person with an Azure role on the workspace |
| The safety copies | Until the retention of the wave ends after the machine is migrated | A person with an Azure role on the resource group |

The run store refuses traffic from outside the install subscription. See [The run store](run-store.md) and [The perimeter around the run store](the-perimeter.md).

## What does the product need from the network?

The product needs no inbound connection to a machine. It reads and changes machines through Azure Resource Manager, and it runs the guest scripts through Azure Run Command. The engine also reads the public Azure retail prices list, with no sign-in. The install creates no virtual network and no private endpoint.

| From | To | When |
|---|---|---|
| The service and the engine | Azure Resource Manager (management.azure.com), Microsoft Entra ID and the run store (blob.core.windows.net) | Always |
| The engine | The Azure retail prices list (prices.azure.com) | During the check of the quota of a wave. The request has no sign-in. |
| The browser of a person | The dashboard, the service and Microsoft Entra ID | Always |
| The browser of an administrator | Microsoft Graph and Azure Resource Manager | On the Admin page |
| A Windows machine | download.microsoft.com over HTTPS | During the move, only when the driver store has no MANA driver |
| A Linux machine | The package repositories that the machine uses | During the move, only when a person chose **Update the kernel** |
| A machine | The Azure Instance Metadata Service at 169.254.169.254 | During the checks. The request does not leave the host. |

The network security perimeter admits only traffic from the install subscription to the run store. See [The perimeter around the run store](the-perimeter.md).

## Can the product give itself more rights?

No. No identity of the product holds `Microsoft.Authorization/roleAssignments/write` or `Microsoft.Authorization/roleDefinitions/write`. No pipeline holds a role in the product.

The install gives its first access as the person who runs it. After that, an administrator gives access on the Admin page with their own rights. They need Owner or User Access Administrator at that place. To add a place to the two roles, they need `Microsoft.Authorization/roleDefinitions/write`. See [The Admin page](../use/admin.md#where-the-product-may-work).

## What does the product never do?

- It does not read your directory with its own identity. The Admin page reads users and groups as the signed-in administrator, with delegated permissions. See [Before you install](../install/before-you-install.md).
- It cannot read Azure role assignments or Key Vault access policies.
- It does not change a subnet, a network security group, a public IP address, a load balancer or an Application Gateway. The roles hold only join actions on them.
- It does not delete or create a machine, and it does not write an extension.
- It reads the preview feature of the in-place upgrade (Preview), and never registers it.
- It does not act on a machine outside its grants. Azure refuses the action, and the product reads its permissions before any change.

<!-- next:begin -->

---

**Next:** [Scale](scale.md)

<!-- next:end -->
