@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Guest scripts write host-visible progress inside VMs; module code must not.
        # Scoped exclusions live here until analyzer supports per-path rules cleanly.
        'PSAvoidUsingWriteHost',
        # PSAvoidUsingInvokeExpression is ON (ANALYZER-IEX-1): nothing uses
        # Invoke-Expression. It reports a Warning, which the gate does not fail
        # on, so tests/unit/AnalyzerInvokeExpression.Tests.ps1 fails on any use.
        # Engine-internal functions use explicit -Force semantics and lease ownership
        # checks instead of ShouldProcess; the interactive-confirm ban (CLAUDE.md rule 7)
        # makes ShouldProcess prompts actively wrong in the execution path.
        'PSUseShouldProcessForStateChangingFunctions',
        # Deliberate plural nouns: Get-VmfExpiredLeases, Read-VmfEvents,
        # Set-VmfOsDiskControllerTypes mirror the plural Azure capability names.
        'PSUseSingularNouns'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('7.2')
        }
    }
}
