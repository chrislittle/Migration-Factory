# If the install fails

The install is safe to run again at any point. Most problems are fixed by correcting one thing and typing `azd up` again.

## The readiness table shows a blocker

The install stops before it creates anything. The **Detail** column says what to fix.

| Check | What to do |
|---|---|
| Azure CLI | Install the Azure CLI version 2.61.0 or a later version. See [Before you install](before-you-install.md). |
| az containerapp extension | In a window that is not opened as administrator, run `az extension remove -n containerapp`, then `az extension add -n containerapp --upgrade`. See [Before you install](before-you-install.md). |
| Signed in | Run `az login` and choose the right subscription with `az account set`. |
| Provider ... cannot be registered | Your account cannot register a resource provider. Ask a subscription Owner to run the command the detail shows. |
| Region offers Container Apps | Choose another region. Run `azd env set AZURE_LOCATION <region>` and then `azd up`. |
| Region offers workload profiles | Choose another region, as above. |
| Container Apps environments in the region | The region's limit is reached. Request a quota increase, or choose another region. |
| Storage accounts in the region | The region's limit is reached. Request a quota increase, or choose another region. |
| Hosting plans | The quota in the region allows neither hosting plan. Free needs a Free plan (F1) and a Consumption plan (Y1). Basic needs a Basic plan (B1). Request a quota increase for the plans of the answer you want, or choose another region. |

The message ends with `azd env set VMF_SKIP_READINESS true`. Set it only when you know that a blocker is wrong. The deployment can then fail later with an error from Azure.

## The install stops after the hosting plan question

The readiness table has a row for each answer: **Hosting plan: Free** and **Hosting plan: Basic**. If the quota in the region does not allow the answer you chose, the install stops before it creates anything. The message names the plan and its quota.

Request a quota increase for that plan, or choose the other answer. To change the answer, run `azd env set VMF_HOSTING_PLAN Basic` (or `Free`) and then `azd up`.

## The install stops and says deployment-stack mode is on

The Azure Developer CLI has a setting called `alpha.deployment.stacks`. This product does not use deployment stacks, and the install cannot finish while that setting is on. The install stops before it creates anything.

Turn the setting off, then run `azd up` again:

```
azd config set alpha.deployment.stacks off
```

The setting belongs to your machine, not to this product, and it reaches every other project you use `azd` for. The install never changes it for you. Turn it back on afterwards if another project needs it.

## You must be logged into Azure

The Azure Developer CLI has its own sign-in. Run `azd auth login` and try again.

## The subscription is not ready

The full sentence names each blocker. Fix them, then run `azd up` again.

## A quota error names a plan type

The readiness table reads the quota of each hosting plan before the install creates anything. When the region does not report it, the deployment error names the plan type. The free choice builds Y1 for the service and F1 for the dashboard. The Basic choice builds one B1 plan for both. In the Azure portal, open **Quotas**, request the quota for that plan type in your region, and run `azd up` again when it is granted. The readiness table can say that the region does not limit App Service plans by type. Then open an Azure support request for the quota type **Function or Web App (Windows and Linux)**.

## The registration was deployed but cannot be read back

Your account created the application registrations but cannot list them. Ask a directory administrator to give your account the right to read applications, or to run the install.

## Building the image failed

The build runs in your registry, in the cloud. The message above the error is from the build itself. The usual cause is a network rule on the registry that refuses the upload. Run `azd up` again once the rule allows it.

## The region has no capacity for Container Apps

```
ManagedEnvironmentCapacityHeavyUsageError: AKS is experiencing heavy usage in
region <region>.
```

The product runs its work in Container Apps, which Azure builds on AKS. When a region has no capacity, the environment cannot be created and the install stops.

Nothing in the product can change this. Wait and run `azd up` again, or install in a different region. The install adopts what the first attempt created.

## The removal said it worked and everything is still there

The removal message can say success while the resource group stays. **Always check:**

```console
az group show --name <your resource group> --output table
```

The answer you want is `ResourceGroupNotFound`.

If the group is still there, nothing is protecting it. Delete it:

```console
az group delete --name <your resource group> --yes
```

Then remove the two application registrations in the Azure portal if the removal did not reach them. They are named after your environment.

## The perimeter could not be created

The install creates a network security perimeter around the run store. Some subscriptions do not permit it, and the install stops with Azure's refusal.

Ask whoever owns policy in your subscription for permission to create a network security perimeter in the product's resource group. It holds one storage account and one rule, and the removal deletes it. See [The perimeter around the run store](../technical/the-perimeter.md).

## The code package could not be put in the store

The message names the publish job, its execution and its status. The install reads the console output of the run while it runs. The message shows the last lines of that output and the path of the file that holds all of it. The file is in the folder of your azd environment, `.azure/<your environment>`.

If the install read the console and got no lines, the message says so. Then the run most likely stopped before its script started: at the image pull, the identity or the start. Run `azd up` again. If it fails again in the same way, report the message as [Something else](#something-else) tells you.

If the install could not read the console, the message gives what Azure said about the read.

Two answers in the output mean different things.

**The request may be blocked by network rules of storage account.** Something refuses the job. This is normal for the first minutes after an install, while the permission the job holds reaches the storage service. The job waits fifteen minutes for it. If it fails after that, the perimeter rule is the next thing to check.

**ContainerNotFound.** The job reached the store and the container is not there. The storage account was created without it. Run `azd up` again.

## Azure answered Too Many Requests

Azure limits the number of requests that your account can send in a time period. When it answers `Too Many Requests` (HTTP 429), the install waits and sends the request again. It waits for the time that Azure gives, or for 10, 20 and 40 seconds. It tries a step 4 times. The install says each wait and the step it waits for.

When the install points a Container Apps job at a new image, it waits on `Too Many Requests` for up to 10 minutes. It says each wait.

When all 4 tries get `Too Many Requests`, the install stops and names the step. Wait a few minutes, then run `azd up` again. The install does not send a request again when Azure refuses it for a different cause, for example a missing permission.

## The service was published but no functions are indexed

The service took longer than four minutes to start after publishing. Wait a minute and run `azd provision` again, as the message says. It publishes again and checks again.

## The install could not grant that reach

The platform is installed and works. The install could not give the product the permission over machines that you chose. Giving it needs Owner or User Access Administrator on the subscription. Give the permission on the Admin page, with an account that holds one of those roles. See [After the install](after-install.md).

## The sign-in rule is not set yet

The install could not yet see the administrator role it gave your account, because the directory had not caught up. Your account still holds the role. Run `azd up` again in a minute, and the install sets the rule.

## Something else

Every message from the install says what it was doing when it stopped. Copy the last 30 lines of the terminal. Report them with the **Get help** menu of the dashboard. If the dashboard is not up yet, report them in the repository's issues.

<!-- next:begin -->

---

**Next:** [Sign in and find your way](../use/sign-in.md)

<!-- next:end -->
