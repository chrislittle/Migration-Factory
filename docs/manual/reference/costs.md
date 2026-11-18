# Costs

Everything runs in your subscription. Azure bills each resource at its list price.

## What the install creates

| Resource | Pricing |
|---|---|
| Azure Container Registry, Basic | [Container Registry pricing](https://azure.microsoft.com/pricing/details/container-registry/) |
| Storage account (the run store) | [Blob Storage pricing](https://azure.microsoft.com/pricing/details/storage/blobs/) |
| Log Analytics workspace and Application Insights | [Azure Monitor pricing](https://azure.microsoft.com/pricing/details/monitor/) |
| Hosting plan: Free (F1 and Y1) or Basic (B1) | [App Service pricing](https://azure.microsoft.com/pricing/details/app-service/windows/) and [Azure Functions pricing](https://azure.microsoft.com/pricing/details/functions/) |
| Container Apps environment and two Container Apps jobs | [Container Apps pricing](https://azure.microsoft.com/pricing/details/container-apps/) |

## What a migration adds

| Resource | Billed |
|---|---|
| Two safety copies of each machine. A copy is a snapshot of each disk. A retry from the first step makes two new copies. | Until the daily cleanup deletes them after the retention of the wave |
| A rollback disk for each disk of the machine, made from the first safety copy | During the move. Then the product deletes each rollback disk that it did not use. |
| On-demand capacity reservation, if chosen | From the moment Azure holds it, used or not, until every machine of the wave has ended and the product releases it, or until you select Release. |
| A Container Apps job | While a wave runs |
| Each machine | At the price of its target size after the move |

## What keeps billing

An on-demand capacity reservation for a wave that does not run. Release it on the Quota and on-demand capacity reservations card of the migration.

These also keep billing until a person acts:

- The disks that a rollback swapped off. They stay in the resource group of the machine, and the panel of the machine lists them. Delete them when you do not need them.
- The safety copies of a machine that did not migrate. The daily cleanup deletes only the copies of a migrated machine. The other copies stay until you delete them, or delete the migration with its copies.

<!-- next:begin -->

---

**Next:** [Architecture](../technical/architecture.md)

<!-- next:end -->
