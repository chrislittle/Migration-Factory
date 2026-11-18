# Update the product

An update is the install command run again from a newer copy of the source. A person runs it from a computer.

## Which copy to update to

There are two answers, and the difference matters.

| Copy | What it is | When to use it |
|---|---|---|
| A **released version** | A version with a name, such as `v0.2.0`. Every test passed on that exact copy of the source before it was published. | Always, unless you have a reason not to. |
| The **newest source** | The tip of the main branch. It holds work that no release names yet. | To take a fix before the next release names it. |

Select the version number at the right of the dashboard's top bar to see which version you hold now.

## The parts in each release

Each released version after `v0.4.0` has a bill of materials. It is a file in the SPDX 2.3 format, attached to the release on GitHub, with the name `vm-migration-factory-<version>.spdx.json`.

| The file lists | For each part |
|---|---|
| Each third-party file that the release contains, such as the sign-in library and the manual's diagram library | The name, the version, the licence, the source package and the checksum |
| Each library that one of those files contains, such as the HTML sanitizer and the d3 charts library in the diagram library | The name, the version and the licence. The version comes from the file, or from the lock file of the release that made the file |
| Each part that the install gets: the base image of the product's container image, the template modules, and the module and extension bundle of the service | The name and the version |

The file lists each part one time. It does not list the tools that build and test the product, such as the CI workflow actions. The install does not contain them.

The service uses one version of the Azure Functions extension bundle, and no module from the PowerShell Gallery. Azure does not change this version. A release that names a newer version brings it when you update.

When a security advisory names a part, find the part in this file. The file tells you if your version contains it.

## Run the update

1. Open PowerShell 7 in the folder that holds the product's source.
2. Get the released version you want and run the install:

```console
git fetch --tags
git checkout v0.2.0
azd up
```

To take the newest source instead of a release:

```console
git checkout main
git pull
azd up
```

The command uses the answers it recorded. It asks the admin consent question again only if you answered Stop. It applies the new templates, builds the product's image again, and publishes the service and the dashboard again. Your runs, plans and records stay in the run store.

At the end, the update reads the admin consent in Microsoft Entra ID. If you answered Yes to the admin consent question, the update first gives admin consent when your organization does not have it. If your organization has admin consent, the update says so and shows no link. If not, it shows the same link as the first install.

A resource that a newer version adds is created. The update does not always remove a resource that a newer version no longer needs.

The update takes about 10 minutes. The dashboard is unavailable for a minute or two while it is published.

## Change one of the two choices

Each choice is a value the install recorded. Set the value, then run the install again.

```console
azd env set VMF_HOSTING_PLAN Basic
azd up
```

To be asked a question again instead of setting the value yourself, set the value to nothing. The install then asks, and records your new answer.

```console
azd env set VMF_HOSTING_PLAN ""
azd up
```

| Value | Meaning |
|---|---|
| `VMF_HOSTING_PLAN` | `Free` or `Basic` |
| `VMF_FIRST_SCOPE` | `no`, `assess` or `migrate`: what the product may do with the machines in the subscription you installed into |
| `VMF_CONSENT_LATER` | `continue`: install without admin consent. Set it to nothing to be asked again. |
| `VMF_ADMIN_CONSENT` | `yes` or `no`: give admin consent for your organization during the install, if you hold a role that can give it. Set it to nothing to be asked again. |

A new answer for `VMF_FIRST_SCOPE` can add permission. It never removes permission. To remove permission, use the Admin page. To give permission, you need Owner or User Access Administrator on the subscription.

Changing the hosting plan replaces the service under a new name. Nothing is lost. The dashboard finds the new service on its own, and keeps its own address. The old service and its plan stay. Delete them: see [The choices you make first](choices.md#choice-1-the-hosting-plan-for-the-dashboard-and-the-service).

## See which version you have

Select the version number at the right of the dashboard's top bar. A dialog shows the version of the dashboard, the service and the part that does the work, and which build each one is.

<!-- next:begin -->

---

**Next:** [Remove the product](remove.md)

<!-- next:end -->
