# Security policy: severity and fix deadlines

This page tells the maintainers how to handle a vulnerability report.
The [SECURITY.md](../SECURITY.md) file at the repository root tells a reporter how to send one.

This page is not part of the manual.
The manual ships inside the dashboard, and it is for the operator of the product.

## Triage

The maintainers triage each report within 7 days of its arrival.

1. Read the report, and try to see the problem again.
2. If the problem is real, give it one severity from the scale on this page.
3. Tell the reporter the severity and the fix deadline.
4. If the problem is not real, tell the reporter why, and close the report.

The fix deadline starts on the day of triage.

## The severity scale

Each severity is for what an attacker can do with the problem, and for what access the attacker must have first.
When two severities are possible, use the higher one.

- **Critical.** An attacker with no access to the install can change or delete a machine, read its disks, or run code in the install.
- **Important.** A signed-in user can do more than the app role of the user allows, or an attacker can read a secret or the run store.
- **Moderate.** The attack needs a condition that is not usual, or the attacker gets only a small result from it.
- **Low.** The problem has no direct effect, but a fix makes a different attack more difficult.

## The fix deadlines

| Severity | Triage | Fix released |
|---|---|---|
| Critical | 7 days | 30 days |
| Important | 7 days | 30 days |
| Moderate | 7 days | 90 days |
| Low | 7 days | 365 days |

A fix is released when a new release that has the fix is available.
If the maintainers cannot release a fix by its deadline, they tell the reporter the new date and the reason.

## The security label

The repository has a label with the name `security`.

1. Do not put the `security` label on an issue while the problem is not public.
2. Keep a report that is not fixed in its private GitHub security advisory.
3. After the advisory is published, put the `security` label on each public issue and pull request for the fix.

Use the label to find every accepted report and its fix.

## Publication

After the release of the fix, publish the GitHub security advisory.
The advisory gives the severity, the versions that have the problem, and the release that fixes it.
Name the reporter in the advisory only if the reporter agrees.
