# Security

## No secrets

No part of the product signs in with a password or a key. Every part signs in with an identity that Azure manages, and every person signs in as themselves with their work account.

The storage account refuses its own access keys. The setting `allowSharedKeyAccess` is off, so a key cannot be used against the run store even if somebody finds one. The service reads and writes the store with its managed identity, and it reads its own program code the same way. This is why the service keeps no file share. Azure Files needs an account key here, so the product does not use it.

Application Insights refuses its instrumentation key. The service sends its telemetry with its managed identity. The identity holds the role Monitoring Metrics Publisher on the Application Insights resource of the product, and on nothing else.

Two logging settings hold a key. The connection string of Application Insights holds one, but Application Insights accepts only Microsoft Entra ID sign-in, so that key cannot send data. The Container Apps environment holds the key of the Log Analytics workspace, and sends the logs of the engine with it.

The Functions host of the service also holds keys. It makes its own host keys and keeps them in the container `azure-webjobs-secrets` of the run store. The install gives a data role on that container only to the service. No function of the service accepts a key. Each function that answers a call has the authorization level `anonymous`. App Service authentication refuses each call that has no Microsoft Entra ID sign-in. Such a call does not reach the Functions host.

The master key also opens the `/admin` endpoints of the Functions host. Microsoft says that App Service authentication examines each call before the application gets the call. Thus App Service authentication also refuses an `/admin` call that has no sign-in. No test measured this on an install for the `/admin` endpoints.

A user can read the host keys in Azure with a role that holds the action `Microsoft.Web/sites/host/listkeys/action`. Owner and Contributor hold this action. The role can be on the service, on its resource group or on its subscription. No identity of the product holds this action.

## Who is who

| Part | Identity | Holds |
|---|---|---|
| A person | Their work account | A role in the product. No access to the run store: the service reads the records for them |
| The dashboard | None. It runs in the person's browser. | Nothing |
| The service | A system-assigned managed identity | Write access to the records in the run store, read access to its own program code, Contributor on the engine job to start the engine, Reader on the Container Apps environment, and the role Monitoring Metrics Publisher on its Application Insights resource. Where an administrator gives the product access, it also holds VMF Assessment, which only reads |
| The engine | A user-assigned managed identity | Write access to the records in the run store, AcrPull on the container registry, and the two custom roles where an administrator granted them |
| The publish job | A user-assigned managed identity | Write access to the program code of the service, AcrPull on the container registry, and no access to the records |

Only the publish job can write the program code of the service. See [The run store](run-store.md#who-may-read-and-write).

## The service is closed

Every call to the service must carry a sign-in from the service's own application registration. Azure enforces this at the platform, before any code runs. An unsigned call gets a refusal, never a page. The install refuses to publish a service that is not configured this way.

Inside, every action checks the caller's role. A viewer cannot approve. Only an administrator can open the Admin page, and the Admin page gives roles with the administrator's own rights.

## The sign-in gate

A person needs a role to sign in at all. The install turns this on once it has given the installer the administrator role. Without a role, the directory refuses the sign-in before the dashboard loads. The identity template preserves the setting on every later run.

## The product's reach

The install asks what the product may do with the machines in the install subscription. Unless the answer is no access, the install grants that role on the whole subscription. An administrator grants the two custom roles on other places on the Admin page, as themselves, with their own rights. The product cannot grant itself anything: no identity of the product holds the right to assign roles.

The two roles are derived from a map of every Azure operation the product performs. A test fails the build when the code gains an operation the map does not list. The roles are never wider than the code.

## The product does not lock its own resources

The product does not stop a person deleting its own resources. Somebody with the right to delete a resource in your subscription can delete one here, as they can in any resource group.

The safety copies are the exception. A rollback or a restore of a machine uses its copies. The engine locks them when it can, and removes its lock when the retention ends.

## Safety copies are locked

The engine locks each safety copy when its identity can write resource locks. The lock stops a person or a script with Contributor rights from deleting the copy. Without that right, the engine takes the copy with no lock, and the activity says so. The engine checks that both copies exist before it changes a machine.

## What the dashboard may read

The dashboard does not read the run store. It asks the service, with the person's own sign-in, and the service reads the records with its own identity. So a role in this product is the whole of what a person needs, and a person who holds no role sees nothing.

Its content policy allows scripts from the dashboard itself and nowhere else. It allows connections only to the service, the directory, Microsoft Graph and Azure. The run store is not in that list, because no page reaches it.

The policy does not allow script inside a page. Each page loads its script from a file of the dashboard, and no button or link in a page holds script. If text from a machine gets into a page without the encoder, the browser does not run it. A test fails the build when a page holds script, or when the policy allows script inside a page.

## Text from machines and from Azure is shown as text

The dashboard shows text that it did not write. This text is the names, tags and extensions of your machines and the results of the guest scripts. It is also the error messages from Azure and the notes that people type. Every page writes this text through one encoder. The encoder changes the characters `<`, `>`, `&`, `"` and `'`, so the browser cannot read the text as part of the page. A link on a page always goes to a page of the dashboard or to an `https://` address.

A test reads the script of every page. It follows each value that a page puts into HTML back to its source. The build fails when a value from a machine, from Azure or from a person gets to the HTML without the encoder. Other tests give the pages and the run report text that contains script, and they make sure that the text stays text.

The report of a run opens in a frame that cannot run script.

## The run store is inside a perimeter

The install puts the run store inside a network security perimeter with one rule: traffic from this subscription may come in. Nothing else may.

Everything the product runs on is in that subscription, so all of it is admitted. Nothing on a computer is, and that is deliberate. See [The perimeter around the run store](the-perimeter.md).

This version keeps no request log of the run store. The activity log and the records of each migration say what the product did, and who approved it. See [The run store](run-store.md#logs-of-the-run-store).

## What the product does not look at

The product does not read your directory to find what a machine identity is used for. It does not ask for the permission `AuditLog.Read.All`. It cannot read Azure role assignments or Key Vault access policies.

No move rebuilds a machine, so no move deletes its system-assigned identity. No restore rebuilds a machine either: a restore changes the machine in place, so it keeps its identity. The product does not find, or give again, the access of a managed identity. No identity of the product can read or write role assignments.

## What is recorded

Every action a person takes carries their name and a note: accepting, approving, starting, pausing, stopping, resolving, restoring. The Admin page gives each role as the administrator who uses it, so the records of Azure and of Microsoft Entra ID name that administrator. Every step the engine takes on a machine is in the machine's history and in the run's log.

<!-- next:begin -->

---

**Next:** [Security and permissions questions](security-faq.md)

<!-- next:end -->
