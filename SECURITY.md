# Security policy

## Report a vulnerability privately

Do not open a public issue for a security problem.
A public issue tells every reader about the problem before a fix is available.

Use GitHub private vulnerability reporting instead.
Only the maintainers of this repository can read a private report.

1. On the main page of this repository, open the **Security** tab.
2. Select **Report a vulnerability**.
3. Complete the form, and then select **Submit report**.

If you cannot see the **Security** tab, open the menu at the end of the row of tabs.

GitHub documents the steps in [Privately reporting a security vulnerability](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability).

## What to include

Give the maintainers enough information to see the problem again.

- The part of the product that has the problem: the dashboard, the service, the engine, a guest script or the install.
- The version of the product, from the About dialog or from the release that you installed.
- The steps that show the problem, from the start.
- What an attacker can do with the problem, and what access the attacker must have first.
- A proof of concept, if you have one.
- Any change that you think will fix the problem.

Do not send a password, a key or a token that works.
Do not send data from a subscription that is not yours.
If a step needs a value like these, replace the value with a placeholder.

## What happens next

1. The maintainers triage each report within 7 days.
2. Triage confirms the problem and gives it a severity: Critical, Important, Moderate or Low.
3. The maintainers tell you the severity and the date by which they plan to release a fix.
4. The maintainers write the fix in a temporary private fork of the repository.
5. After the release of the fix, the maintainers publish a GitHub security advisory.

The advisory names you as the reporter only if you agree.
The [security policy](docs/security-policy.md) gives the severity scale and the fix deadline for each severity.

## Supported versions

The maintainers fix vulnerabilities in the latest release only.
To get a fix, install the latest release.

## Problems that are not in this product

This policy is for the code in this repository.
Report a vulnerability in Azure itself to the [Microsoft Security Response Center](https://msrc.microsoft.com/report/vulnerability).
