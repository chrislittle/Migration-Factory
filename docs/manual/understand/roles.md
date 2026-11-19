# Who does what

Two kinds of identity act in this product: people, and the product itself. Each holds only the rights its job needs.

## People

A person signs in to the dashboard with their normal work account. What they can do depends on the roles they hold in the product. An administrator gives roles on the Admin page.

| Role | What it allows |
|---|---|
| Viewer | Sees every page. Changes nothing. |
| Approver | Everything a viewer can do. Accepts assessments. Approves waves, and signs off the plan. Accepts a decision for one machine that stopped. Removes the sign-off requirement from a wave. |
| Operator | Everything a viewer can do. Starts assessments and migrations. Chooses the machines and their targets, and arranges the waves. Accepts the settings of each wave. Starts, pauses and stops waves. Tries a stopped machine again, or leaves it out. Restores machines from safety copies. Cannot remove the sign-off requirement from a wave. |
| Administrator | Everything. Gives and removes roles. Gives the product permission to see and change machines. |

A person can hold more than one role. The Admin page says when another role already covers a role.

Every action a person takes is recorded with their name and a note they write. Approving a wave, accepting its settings, starting it, stopping it, and every decision on a stopped machine all carry a name.

A person needs no right in Azure to use the product, because the service reads the migration records for them. To give the product permission on the Admin page, an administrator also needs Owner or User Access Administrator at that place.

## The product

The product has its own identity in Azure. It uses that identity to read machines and to change them. The install asks what the product may do with the machines in the install subscription. Unless the answer is no access, the install gives that permission on the whole subscription. An administrator gives permission on other places on the Admin page:

- **Assess** lets the product read the machines in a place and report what could move. It changes nothing. It is safe to give broadly, for example on a whole subscription.
- **Assess and migrate** lets the product also stop and resize the machines in a place. Give it as narrowly as your estate allows, for example on one resource group.

The permission is two custom roles that the install creates. They contain exactly the operations the product performs, and nothing more. The product cannot grant itself anything. See [What the product may do in Azure](../reference/permissions.md).

## Updates

A person updates the product from a computer, with their own rights in Azure. No pipeline identity holds a role on the platform. See [Update the product](../install/update.md).

## The daily cleanup

The service runs a small task every day from 03:30 UTC. It deletes safety copies whose retention has ended, and the disks made from the copies that nothing used. The service finds what is due, and the product deletes it with the VMF Migration role. The service writes a record of every pass. The task runs every hour in short passes. Each pass starts at the migration where the last pass stopped. When the task has examined every migration, it waits until 03:30 UTC on the next day.

<!-- next:begin -->

---

**Next:** [Words used in this manual](words.md)

<!-- next:end -->
