# Remove the product

Removing the product deletes every resource the install created, the resource group included. It does not touch any machine you migrated. Those machines stay on their new size.

## Before you remove it

Save the reports and the migration records you want to keep. See [Reports](../use/reports.md). The run store goes with the product.

Release every on-demand capacity reservation you do not need. On the **Quota and on-demand capacity reservations** card of the migration, or in the wave editor, select **Release** on each wave. After the removal there is no Release control. See [Capacity and quota](../use/capacity.md).

Remove the access you gave the product. Open the **Admin** page. Under **Where the product may work**, select **Remove** beside each row, then **Yes, remove access**. This deletes the role assignments at each scope, as your user, so you need Owner or User Access Administrator there. If you skip this step, they stay after the removal. See [What stays behind](#what-stays-behind).

## What happens to the safety copies

A safety copy is a snapshot the product took before it changed a machine. Each copy is in the resource group of that machine, not in the product's. The removal leaves every copy where it is.

The removal also deletes the daily pass that removes a copy when its retention ends. From that moment the copies stay until you remove them.

The removal tells you how many are there. It does not stop.

## Find the copies, now or later

This command works after the product is gone:

```console
az resource list --tag vmfSafetyCopy=true -o table
```

Each copy carries tags: the machine it came from, the run that took it, and the days its wave keeps it.

To remove one copy, delete its lock first. The lock is what stops a delete:

```console
az lock delete --name vmf-safety-copy --resource-group <group> --resource <snapshot> --resource-type Microsoft.Compute/snapshots
```

```console
az snapshot delete --name <snapshot> --resource-group <group>
```

Some copies can carry no tags, because a policy in your subscription can remove tags. List those by their lock:

```console
az lock list --subscription <id> -o table
```

The lock named `vmf-safety-copy` is on each copy, and its scope names the copy.

## What happens to the on-demand capacity reservations

An on-demand capacity reservation holds a reserved quantity of one size for a wave. Azure bills the quantity that no machine uses until the capacity reservation is deleted. Each capacity reservation group is in the resource group of its machines, not in the product's, so the removal leaves it.

The removal lists every capacity reservation group the product made. It does not stop. Find them now or later with this command:

```console
az resource list --tag vmfCapacityReservation=true -o table
```

A policy in your subscription can remove the tag from a group. The name of each group starts with `vmf-`, then the run and the wave. List every group in the subscription to find them:

```console
az resource list --resource-type Microsoft.Compute/capacityReservationGroups -o table
```

## Delete a capacity reservation in Azure

**Release** sets the reserved quantity to 0, removes the machines from the group, and deletes the group. Use the steps below only for an on-demand capacity reservation that nobody released. Its machines are still in the capacity reservation group, and Azure refuses to delete a group that holds a machine. Do the steps in this order.

1. Set the reserved quantity of the capacity reservation to 0. The machines keep running:

```console
az capacity reservation update --ids <reservation id> --capacity 0
```

2. Remove each machine from the group. Do this for each machine the group lists:

```console
az vm update --ids <machine id> --capacity-reservation-group None
```

3. Delete the capacity reservation, then the group:

```console
az capacity reservation delete --ids <reservation id> --yes
```

```console
az capacity reservation group delete --ids <group id> --yes
```

## Remove it

1. Open PowerShell 7 in the folder that holds the product's source.
2. Type this and press Enter:

```console
azd down
```

The command first counts the safety copies and the capacity reservation groups, and says where to find them. If it cannot count them, or can count only some, it says why. It does not stop.

Then it deletes every resource and the resource group. **This takes about 35 minutes.** The Container Apps environment takes most of this time. Let the command run.

Last, it asks whether to remove the two application registrations from your directory. **Yes** is the default: press Enter to remove them. Answer **No** to keep them for a later install with the same environment name. This question comes after the resources are gone: a removal that stops part way leaves a product you can still sign in to.

## Check that the resource group is gone

The removal can report success and leave everything in place. Do not take the message for the result:

```console
az group show --name <your resource group> --output table
```

The answer you want is `ResourceGroupNotFound`. If the group is still there, see [If the install fails](if-it-fails.md).


## What stays behind

- The two custom roles in your subscription, VMF Assessment and VMF Migration. They hold no permission on their own and cost nothing. Another install in the same subscription uses them again. To delete them, first remove every assignment of them. Then delete each role in the access control (IAM) of the subscription.
- The access you gave the product on the Admin page, if you did not remove it before the removal. These role assignments point at an identity that no longer exists, so they give no access. The Azure portal shows them as "Identity not found". Remove them in the Azure portal: open the access control (IAM) of each scope, select **Role assignments**, and remove each one.

## Do not stop it part way

The removal deletes the resources first. It asks about the two application registrations only after the resources are gone. If you stop it part way, some resources can stay and still cost money.

If that happens, run the removal again. It finishes what it started.

## If you install again

The removal also clears the two choices you made. The install asks them again.

If an attempt fails part way, type `azd up` again. The install adopts every resource the first attempt created and continues. See [If the install fails](if-it-fails.md).

Microsoft Entra keeps a deleted application registration for 30 days, and it keeps the name with it. The two registrations this product creates are named after your environment, so installing again with the **same environment name** meets those kept names. The install gives the new registrations a new unique name. The names you see in the portal do not change.

The install removes the deleted registrations that hold the names, and says so:

```
removing a deleted registration still holding the name 'vmf-api-<your environment>'
```

If your account may not remove them permanently, the install stops and gives you the command to send to a directory administrator. You can also install with a different environment name, which gives every registration a different name.

<!-- next:begin -->

---

**Next:** [If the install fails](if-it-fails.md)

<!-- next:end -->
