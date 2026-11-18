# Sign in and find your way

## Sign in

Open the dashboard address in a browser. The address ends in `azurewebsites.net`; the install printed it, and the administrator can give it to you.

The page shows one card. It gives the product name, says what the product does, and has one button: **Sign in with Microsoft Entra ID**.

Select the button. The browser goes to Microsoft. Sign in with your work account, and Microsoft sends you back to the page you started from. **Sign-in and sign-out open no pop-up window**, so a pop-up blocker cannot stop them.

## The first time you sign in

Microsoft shows a page asking to approve what the dashboard may do. **In most directories you can approve this yourself.** It asks only to call the migration service on your behalf, and to read Azure as you for the Admin page. Microsoft Entra reserves neither of those for an administrator.

Everything the product does day to day works from here: assessments, migrations, waves, reports.

Your directory can be stricter. A directory can let a user approve only the permissions an administrator marked as low impact, or let a user approve nothing at all. Then Microsoft refuses, and an administrator must approve the product before anyone signs in. Ask your directory administrator, and read the next part.

## The Admin page needs an administrator, once

The **Admin page** is the one part that does not. It reads your directory to show who can sign in, and to give and remove roles, and Microsoft Entra reserves those permissions for an administrator. **No user can approve them, in any directory.**

Until somebody approves it, only the person who installed the product can sign in. The Admin page is where a role is given, and a person needs a role.

Ask whoever looks after your Microsoft Entra directory. Any one of these roles is enough: Global Administrator, Privileged Role Administrator, Cloud Application Administrator, Application Administrator, or AI Administrator. Cloud Application Administrator is the role with the fewest rights that can give it.

**If your directory has the admin consent request workflow on,** open the Admin page. When Microsoft asks for approval, type a reason and select **Request approval**. A reviewer approves it in the Microsoft Entra admin center, in **Enterprise apps**, then **Admin consent requests**.

**If the person who installs holds one of these roles,** the install asks to give admin consent, and gives it if they answer Yes. Then the install reads the consent again. When it shows admin consent for every permission, nothing is left to do.

**Otherwise, the install prints a link for it.** Send the link to the person with the role. They open it, read the permissions, and select **Accept**. When your organization has admin consent, the install and each update say so and print no link.

A user who approves the product only for themselves does not give admin consent for your organization. The install reads this too. It says that the product works for that user and for nobody else, and it prints the link.

They can also approve it from the sign-in page itself. Or, in the Microsoft Entra admin center: **App registrations**, then the dashboard's registration. On its permissions page, select **Grant admin consent**.

## After that

One thing must be true before you see anything:

- **You hold a role in the product.** An administrator gives roles on the Admin page. Without a role, the dashboard shows **You do not have access to this app yet**, the account you signed in with, and **Sign out**.

When no migration exists, the Migrations page shows **Nothing to show yet**. It checks three conditions: **You are signed in**, **You have been given a role in the product** and **You can read the migration records**.

## The disclaimer

The first time you sign in to the dashboard with a browser, it shows the [disclaimer](../understand/disclaimer.md) once. Select **OK**, press Escape or select outside it to close it. The dashboard does not show it again in that browser. If your browser does not keep site data, the dashboard shows it once on each page that you open.

At the bottom of every page, a short line says that Migration Factory is not an official Microsoft product. **Read the disclaimer** opens the full notice in this manual, in the same tab.

## The top bar

Every page has the same top bar.

| Item | What it does |
|---|---|
| Overview | What is waiting for you, and what runs now. |
| Projects | The estates you look after. |
| Assessments | Every look at your machines, and whether it was accepted. |
| Migrations | Every migration, and the page where you watch and control one. |
| Reports | What happened, after the fact. |
| Admin | Who can use the product, and where it may work. Administrators only. |
| Get help | Explains the page you are on, opens this manual, reports a problem. |
| Light, Dark, Follow the system | The colours of the pages. |
| Version | Which version of the product you are using. Select it for details. |
| Sign out | Ends your session in this browser and at Microsoft. The browser goes to Microsoft, which signs you out and sends you back to the page you started from. The next sign-in asks which account to use. |

When a migration is open, a second bar under the first names it and offers **Refresh now**.

## Where things are

The dashboard follows the order of the work. Start at Projects. Assess from a project. Review the assessment on Assessments. Plan and start from the migration's own page. Watch it there. Read what happened on Reports.

Each row in the list on the Overview page opens its migration or its assessment.

## If the wizard says the service did not answer

On the Free plan, Azure can stop the service when nobody uses it. The service starts again on the next request. If a step of the wizard says **The service did not answer. Try again.**, wait a moment, then do the step again.

<!-- next:begin -->

---

**Next:** [The Overview page](overview.md)

<!-- next:end -->
