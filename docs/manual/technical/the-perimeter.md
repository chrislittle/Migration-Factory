# The perimeter around the run store

The install creates a network security perimeter and puts the run store inside it.

## What it is

A network security perimeter is an Azure resource that decides what may reach the resources inside it. The install creates one, `vmf-nsp-<suffix>`, and associates the run store with it.

The perimeter carries one rule: **traffic from this subscription may come in.** Nothing else may. The rule admits all traffic from resources in this subscription, so the data roles decide who reads the run store.

Everything the product runs on is in that subscription. The engine and the publish job are Container Apps jobs, and the service is a function app. These three reach the run store, and only they hold a data role on it. The dashboard does not reach it.

## Why it is there

An Azure Policy with the modify effect can close public network access on every storage account as it is created. The policy wins over any setting in a template, and it reports success while it does so.

With the run store closed, nothing on the public path can read or write it. The product cannot work.

The perimeter is the way through. The rule admits the service, the engine and the publish job from inside Azure. So the product works while the store stays closed to everything else.

If your subscription has no such policy, the perimeter still applies. The product works the same way in both.

## The logs are outside it

The Log Analytics workspace and Application Insights are not in the perimeter. The services send their logs there, and you query them with your own Azure role. You do not change the perimeter to read the logs.

This version keeps no request log of the run store. See [The run store](run-store.md#logs-of-the-run-store).

## What it means for you

**Nothing on your computer reaches the run store.** Not the install, not the dashboard in your browser, not a command you type. The service reads and writes the records for you. This is by design: a perimeter rule admits a subscription, and your computer is not in a subscription.

**One perimeter per resource.** Azure puts a resource inside one perimeter at a time. If your network team wants the run store inside their perimeter, they must first remove the association this install made. The error Azure gives if they do not names the association and nothing else.

**The removal deletes it.** The perimeter is in the product's resource group, so `azd down` deletes it with everything else.

## How to see that it is healthy

In the Azure portal, open the perimeter, then **Associated resources**. It shows the access mode of the run store, and each issue that Azure raised against the association.

**The run store has a managed identity.** Azure asks for one on every resource in a perimeter, because two resources inside the same perimeter identify themselves to each other that way. The identity holds no role and reaches nothing. Without it, Azure raises an issue against the association and keeps it there.

## If the install cannot create one

Some subscriptions do not permit it. The install stops with Azure's own refusal, which names the perimeter.

Ask whoever owns policy in your subscription for permission to create a network security perimeter in the product's resource group. It covers one storage account, it holds one rule, and it goes away when the product does.

## A change takes minutes to apply

A rule added or removed is not immediate. A service keeps its connections open, so it goes on working for some minutes after a rule stops admitting it.

Wait 40 minutes before you decide a change to the perimeter did nothing.

<!-- next:begin -->

---

**Next:** [Security](security.md)

<!-- next:end -->
