# The choices you make first

The install asks two questions once. It records your answers and does not ask them again. If you hold no role that can give admin consent, it asks one more question first: stop or continue. It records Continue, but not Stop, so after a Stop it asks again. If you hold a role that can give admin consent and your organization does not have it, the install asks to give it. You can change an answer later; the page [Update the product](update.md) shows how.

A person updates the product. Get a newer copy of the source, then run the install command again from your computer. No automation identity holds any right on the platform. The page [Update the product](update.md) shows the commands.

## First: admin consent

Before the install creates anything, it says that the full product needs admin consent in Microsoft Entra ID. It names the roles that can give it, and it recommends Cloud Application Administrator. Then it reads your roles.

**You hold one of the roles.** The install continues. After it creates the registrations, it reads the admin consent of your organization. If your organization does not have admin consent, the install asks: **Give admin consent for your organization now?** Before the question, it lists each permission that admin consent approves.

- **Yes.** This is the default. The install gives admin consent as the signed-in user, with your directory role. It uses no other identity and no secret. Then it reads the admin consent again. The install says that your organization has admin consent only when Microsoft Entra ID shows it for every permission. If Microsoft Entra ID refuses, or shows only some permissions, the install continues. At the end, it gives you the link to give admin consent yourself.
- **No.** The install gives no admin consent. At the end, it gives you the link to give it yourself.

The install records this answer in `VMF_ADMIN_CONSENT`, so it does not ask again. After Yes, a later install gives admin consent again if your organization does not have it. An install with no console takes Yes.

**You hold none of them.** The install asks: stop now, or install without admin consent?

- **Stop.** This is the default. The install stops before it creates anything. Run the install again with a person who holds one of the roles. The install does not keep this answer, so it asks again next time.
- **Continue.** The install continues, and you can assess and migrate as usual. At the end, it tells you how to get admin consent from a person who holds one of the roles. If your directory has the admin consent request workflow on, you request it from the Admin page. If not, you send that person a link. They open it in a browser and approve it. Nobody runs a command. The install records this answer in `VMF_CONSENT_LATER`, so it does not ask again on a later install.

An install with no console continues, and prints the same information at the end.

**The install cannot read your roles.** It says so, and it does not guess. It does not ask the question, and it continues.

**A role that is eligible in Privileged Identity Management does not count until it is active.** The install reads only active roles. If you hold an eligible role, activate it and run the install again.

## Choice 1: the hosting plan for the dashboard and the service

The dashboard and the service behind it run on Azure hosting plans. One choice covers both.

Free uses App Service Free (F1) for the dashboard and Azure Functions Consumption (Y1) for the service. Basic uses one App Service Basic (B1) plan for both, with Always On. Free is the default.

Changing this later builds a new service, because Azure does not move a service between these two plan kinds. Nothing is lost, because every record lives in the run store, not in the service. The dashboard is not built again: it moves to the other plan and keeps its address.

**The old service and its plan stay, and you delete them.** The install does not remove the old plan. Delete them in the resource group. After Basic to Free, delete the function app `vmf-facade-b1-<suffix>` and the plan `vmf-plan-b1-<suffix>`. After Free to Basic, delete the function app `vmf-facade-<suffix>` and the plans `vmf-facade-plan-<suffix>` and `vmf-dash-plan-<suffix>`.

## Choice 2: what the product may do with your machines

The product starts with no permission over any machine. This question gives it the first one.

**The install reads what your account can do, and says so, before it asks.** Two different rights decide this question, and they are different rights:

- **Owner or User Access Administrator on the subscription** lets you give the product permission over machines. Without one of those, the install does not ask. It tells you who to ask instead, and records **Nothing now**.
- **A directory role that can give admin consent** lets you use the Admin page. Cloud Application Administrator is the role with the fewest rights that can give it. Global Administrator, Privileged Role Administrator, Application Administrator and AI Administrator can also give it.

The answers offered follow what it found.

**Scan the machines in this subscription. Change nothing.** The product may read the machines in this subscription. This is what an assessment needs.

**Scan them, and migrate a machine after you approve a migration.** This is what a migration needs.

**Nothing now.** Choose the place on the Admin page instead. That page covers a resource group, a subscription or a management group, and removes permission again. It is the fuller route, and it needs admin consent in Microsoft Entra ID.

**The default is to scan and migrate.** If you can grant the permission, pressing Enter gives you a product that can migrate. If you can use the Admin page, it is listed first, because it can do more than this question can.

**A grant changes no machine.** The product changes a machine only after you plan a migration and approve it.

**If a read is refused, the install says so and offers every answer.** Your directory can refuse to tell the install which roles you hold, also for a Global Administrator. Then choose the answer that your roles allow.

## The two choices made for you

**One resource group holds the platform.** The install creates it and puts every resource in it. The removal deletes the group, which deletes everything inside.

The product does not lock those resources. A person with the right to delete a resource in your subscription can delete one here. This is the same as any other resource group you own.

Your migration records are in the storage account in that group. Save the reports and records you want to keep before you remove the product. See [Reports](../use/reports.md).

**The product gets no permission you did not give it.** Choice 2 is the only permission the install grants over your machines. It covers only the subscription you install into. The product has two identities that get these roles: the one that does the work on machines, and the service. **Scan the machines in this subscription. Change nothing.** gives VMF Assessment to both. **Scan them, and migrate a machine after you approve a migration.** gives VMF Migration to the first, and VMF Assessment to the service. After the install, an administrator adds or removes permission on the Admin page, place by place, with their own rights.

<!-- next:begin -->

---

**Next:** [Install step by step](step-by-step.md)

<!-- next:end -->
