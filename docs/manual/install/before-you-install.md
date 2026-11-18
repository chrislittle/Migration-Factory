# Before you install

The install takes about 20 minutes. It asks about the hosting plan and about what the product may do with the machines. If you hold no role that can give admin consent, it also asks if you stop or continue. If you hold one, it asks to give admin consent for your organization. [The choices you make first](choices.md) explains each one.

## What the install creates

One command creates everything inside one new resource group in your subscription:

| What | Why |
|---|---|
| A storage account | The run store. Every record the product writes lives here. |
| A container registry | Holds the product's image, built from its source in your own subscription. |
| A Container Apps environment and two jobs | One job does the work of the product: an assessment, a plan, a wave or a restore. It runs only while it has work. The publish job puts the code of the service in the run store, during an install or an update. |
| A function app on a hosting plan | The service behind the dashboard. |
| A web app on a hosting plan | The dashboard. With the Basic choice, both apps share one plan. |
| A Log Analytics workspace and Application Insights | Where the product writes its logs. |
| Three managed identities | One for the service and one for each job. The product gets permission over machines only from your answer to the install's question, or from the Admin page. |
| A network security perimeter | Holds the run store. One rule: traffic from this subscription may come in. |

Outside the resource group, the install creates:

- Two application registrations in your Microsoft Entra directory. One signs people in to the dashboard. The other guards the service. Both are named after the environment name you choose.
- Two custom roles in your subscription: VMF Assessment and VMF Migration. VMF Migration contains VMF Assessment. They contain exactly the operations the product performs. Every install in the subscription uses the same two roles, and a removal of the product keeps them.

The install does not create any virtual machine, and it does not touch any machine you have.

## What it costs

The install asks you to choose a hosting plan: Free or Basic (see the next page). See [Costs](../reference/costs.md).

## What you need

**Tools on your computer.** Install these, in any order. Docker is not needed: the product's image is built in your own registry, in the cloud.

| Tool | What it is for | Where to get it |
|---|---|---|
| Azure CLI, version 2.61 or later | Everything the install reads and writes in Azure | https://aka.ms/installazurecli |
| Azure Developer CLI | The `azd up` command itself | https://aka.ms/azd-install |
| PowerShell 7 | The install steps run in it | https://aka.ms/powershell |
| Git | Gets the product's source | https://git-scm.com/downloads |
| The `containerapp` extension for the Azure CLI | The install needs it for one command | The install adds it if it is not installed |

Before it creates anything, the install checks the version of the Azure CLI and the `containerapp` extension. If one of them is missing or cannot be used, the install stops and gives the repair.

**Add Azure CLI extensions from an ordinary window, never from one opened as administrator.** An extension belongs in your own profile, and an ordinary account owns it. One installed from an administrator window is owned by Administrators, and then the Azure CLI cannot read it from your ordinary window. Then every `az containerapp` command fails with "Access is denied".

To repair the permissions, in PowerShell as administrator:

```
icacls "$env:USERPROFILE\.azure\cliextensions" /reset /T
```

Then run the install again in an ordinary window.

**An account.** Your work account must hold:

- The Owner role on the subscription. The install creates the resource group and two custom roles in the subscription, and it gives roles.
- The right to create application registrations in your Microsoft Entra directory. Most accounts have it. If yours does not, an administrator of the directory can grant it, or run the install for you.
- **For the full product, a directory role that can give admin consent.** The Admin page needs admin consent in Microsoft Entra ID. Use **Cloud Application Administrator**. It is the role with the fewest rights that can approve every permission of this product. Global Administrator, Privileged Role Administrator, Application Administrator and AI Administrator can also give it.

Without a role that can give admin consent, you can still install, assess and migrate. The install tells you, and asks you to stop or continue. Stop is the default: start the install again with a person who holds the role. If you continue, the install ends with a link to send to that person. See [The choices you make first](choices.md).

A role that is eligible in Privileged Identity Management counts only when it is active. Activate it before you start the install.

**A directory administrator, once - for the Admin page only.** In most directories you can install and use the product without one. Signing in, assessments, migrations and reports ask only for permissions a user may approve.

Your directory can be stricter, and it is worth knowing before you install. A directory can let a user approve only the permissions an administrator marked as low impact, or let a user approve nothing at all. Then an administrator must approve the product before the first sign-in. To read your directory's rule, run this from the source folder. It only reads, and it changes nothing:

```console
./tools/Test-VmfConsentReadiness.ps1
```

It names your directory's rule, says whether you can approve, and names the roles that can. It ends with the steps to get admin consent, the same steps the install shows. It does not give a command to run.

After the install, add the name of the dashboard registration, for example `-DashboardDisplayName vmf-dashboard-<environment>`. The check then tells you if your organization has admin consent, and gives the link if it does not.

The **Admin page** is different. It reads your directory to show who can sign in, and to give and remove roles, and Microsoft Entra reserves those permissions for an administrator. **No user can approve them, in any directory.** This is one action, done one time, after the install.

| Permission | Why the dashboard needs it |
|---|---|
| `AppRoleAssignment.ReadWrite.All` | Give and remove a person's role on the Admin page |
| `Application.Read.All` | Read the product's own registration to show the roles it offers |
| `Group.Read.All` | Show groups, so a role can be given to a group |

The person who does this needs one of these directory roles: Cloud Application Administrator, Application Administrator, AI Administrator, Privileged Role Administrator or Global Administrator. Cloud Application Administrator is enough, because every permission of this product is delegated. Microsoft names it as the role with the fewest rights that can approve delegated permissions.

If you hold one of these roles, the install asks to give admin consent for you, as the signed-in user. Answer Yes, and nobody has to do it later. Another person does it in the browser. The install ends with a link for it. They open the link, read the permissions, and select **Accept**. After that, each install and update reads the admin consent and shows no link.

Until it is done, you are the only person who can sign in. The Admin page is where a role is given, and a person needs a role. See [Sign in and find your way](../use/sign-in.md).

**A region.** Choose a region that offers Azure Container Apps with workload profiles. The install checks before it creates anything, and it names the region if the check fails.

**A terminal.** Type every command in this manual in PowerShell 7. The install and the product's tools are PowerShell scripts.

To check that a tool is installed, open a terminal and type its name followed by `--version`. Each one prints its version.

```console
az --version
azd version
pwsh --version
git --version
```

## The two sign-ins

The Azure CLI and the Azure Developer CLI each keep their own sign-in. The install uses both, so you sign in twice, with the same account. The step-by-step page shows both commands.

## Choose an environment name

The install asks for an environment name. Choose it now. It becomes the name of the resource group, with `rg-` in front. It also names the two application registrations, with `vmf-api-` and `vmf-dashboard-` in front. Use lowercase letters, numbers and dashes. `vmf-prod` is a good name. The name cannot be changed later without removing the install.

<!-- next:begin -->

---

**Next:** [The choices you make first](choices.md)

<!-- next:end -->
