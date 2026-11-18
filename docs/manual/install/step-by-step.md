# Install step by step

Follow these steps in order. Each step says what you type, what you see, and what to do if something else appears. The whole install takes about 20 minutes.

The Container Apps environment takes most of this time. Let the command run.

Before you start, read [Before you install](before-you-install.md) and [The choices you make first](choices.md).

## Step 1: open a terminal

Open PowerShell 7 on your computer. On Windows, search the Start menu for **pwsh**. Every command in this page is typed into that window.

## Step 2: sign in to the Azure CLI

> Type this and press Enter:
>
> ```console
> az login
> ```

A browser window opens. Sign in with your work account. When it finishes, the terminal lists your subscriptions.

If you have more than one subscription, select the one to install into:

```console
az account set --subscription "<the subscription name or id>"
```

## Step 3: sign in to the Azure Developer CLI

> Type this and press Enter:
>
> ```console
> azd auth login
> ```

A browser window opens again. Sign in with the same account. The terminal says **Logged in to Azure**.

## Step 4: get the source

The install runs from a copy of the product's source on your computer. Choose one of the two ways.

**Way 1: clone the repository with Git.**

```console
git clone https://github.com/chrislittle/Migration-Factory.git
cd Migration-Factory
```

**Way 2: let the Azure Developer CLI fetch it.** This also asks for the environment name.

```console
azd init -t chrislittle/Migration-Factory
cd Migration-Factory
```

Either way, you end in a folder that holds a file named `azure.yaml`. That file is what the next command reads.

## Step 5: run the install

> Type this and press Enter:
>
> ```console
> azd up
> ```

The command asks a few questions before it does anything.

1. **Environment name.** Type the name you chose, for example `vmf-prod`, and press Enter. If you used Way 2 above, this was already asked.
2. **Subscription.** Choose from the list with the arrow keys and press Enter.
3. **Location.** Choose the region and press Enter.

Then the install shows the [disclaimer](../understand/disclaimer.md) before it deploys anything. Migration Factory is not an official Microsoft product, and Microsoft does not support it.

Then the install checks that the subscription is ready. It prints a table like this:

```
Check                                     Result  Detail
Azure CLI                                 ok      az <version>
Azure Developer CLI                       ok      azd version <version>
PowerShell                                ok      PowerShell <version>
az containerapp extension                 ok      version <version>
Signed in                                 ok      you@example.com on <subscription>
Provider Microsoft.App                    ok      registered
...
Region offers Container Apps              ok      <region>
Region offers workload profiles           ok      Consumption profile, <n> profile type(s)
Container Apps environments in the region ok      <n> of <limit> used; the platform needs 1
Storage accounts in the region            ok      <n> of <limit> used; the platform needs 1
Hosting plan: Free                        ok      Free needs 1 Free plan (F1) and 1 Consumption plan (Y1), and the quota in <region> allows them.
Hosting plan: Basic                       ok      Basic needs 1 Basic plan (B1), and the quota in <region> allows them.
```

Each line says **ok**, **warn**, **unknown** or **blocker**. A line that says **blocker** stops the install and names what to fix. A **warn** on a hosting plan line means that the quota does not allow that plan, and the install refuses it if you choose it. See [If the install fails](if-it-fails.md).

Then the install asks its questions. Each question lists its answers with a number. Type the number and press Enter, or press Enter alone for the default. If you hold no role that can give admin consent, it first asks if you stop or continue. See [The choices you make first](choices.md).

```
Choose the hosting plan for the dashboard and the service
  1) Free: App Service Free (F1) for the dashboard, Azure Functions Consumption (Y1) for the service. (default)
  2) Basic: one App Service Basic (B1) plan for both, with Always On.
Type the number, or press Enter for the default:
```

Then it asks **What may the product do with the machines in this subscription?** It does not ask this when you hold neither Owner nor User Access Administrator on the subscription.

After the last answer the install runs on its own. It prints what it does as it goes:

1. It creates the resource group and the two application registrations.
2. It creates every resource in the resource group. The Container Apps environment takes most of this time.
3. It builds the product's image in your registry.
4. It publishes the service and the dashboard.
5. It makes your account the administrator. From then on, a person needs a role to sign in.
6. It checks that the service answers.
7. It gives the product the permission that you chose.
8. If your organization has no admin consent and you can give it, it asks to give it. If you answer Yes, it gives admin consent as you, then reads it again.
9. It says if your organization has admin consent. If not, it gives the link for it.

The last lines look like this:

```
Installed.
   Open https://vmf-dash-<letters>.azurewebsites.net and sign in.
   You are the administrator. Nobody else can sign in until you give them a role on the Admin page.
   This install may SCAN AND MIGRATE machines in subscription <subscription id>.
```

That is the default answer. After **Nothing now**, or with no question, the last lines say that the install gave the product no reach over your machines. Then give the product permission on the Admin page.

## Step 6: open the dashboard

Copy the address from the last lines into a browser. Sign in with the same work account. You see the Overview page with nothing in it yet.

Continue with [After the install](after-install.md).

## If the command stops part way

The command is safe to run again at any point. Type `azd up` again. Every step adopts what already exists and continues from there. See [If the install fails](if-it-fails.md) for the messages you might see.

<!-- next:begin -->

---

**Next:** [After the install](after-install.md)

<!-- next:end -->
