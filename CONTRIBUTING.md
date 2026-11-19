# Contributing

## Report a problem

Open an issue, and use the bug report form or the feature request form.

Do not open a public issue for a security problem. [SECURITY.md](SECURITY.md) tells you how
to report one privately.

## Pull requests

This repository does not accept pull requests from outside contributors yet. Open an issue
instead. The maintainer makes each change, and the change arrives here with the next release.

## Checks

Every change passes every check before a release. Run them with:

```powershell
./tools/Invoke-VmfTests.ps1
```

The checks need PowerShell 7, Pester 5.9.1, PSScriptAnalyzer 1.25.0, Node.js and the Bicep CLI.
They do not sign in to Azure.