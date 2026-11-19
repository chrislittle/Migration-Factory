#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# AUTHREAD-1, 2026-09-09, MEASURED on a live install. The gate that refuses to
# publish to a control plane not behind sign-in (EVAL-H13) CRASHED instead of
# refusing:
#
#   The property 'globalValidation' cannot be found on this object.
#
# It killed the publish after the engine image was built and the job repointed,
# with a message naming a property and nothing a person could act on.
#
# WHY IT THREW THERE AND NOWHERE ELSE is the part worth keeping.
# Deploy-VmfFacade.ps1 sets no strict mode. postprovision.ps1 dot-sources
# AzdHooks.ps1, which sets Set-StrictMode -Version Latest, and STRICT MODE IS
# INHERITED BY CHILD SCOPES. Run from a shell, the absent property reads as
# $null and the refusal fires correctly. Run from the hook, the same line is
# fatal. The same code, two behaviours, decided by the caller.
#
# These tests take the walker OUT OF THE SHIPPED SCRIPT and run it, so they
# cannot pass against a copy that has drifted from what deploys.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:path     = Join-Path $script:repoRoot 'tools' 'Deploy-VmfFacade.ps1'
    $script:source   = Get-Content $script:path -Raw

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:path, [ref]$null, [ref]$null)
    $assignment = @($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -eq '$readAuth'
    }, $true))
    if ($assignment.Count -ne 1) { throw "expected one `$readAuth assignment, found $($assignment.Count)" }
    # The right side is a scriptblock literal, so running it hands back the walker.
    $script:walk = & ([scriptblock]::Create($assignment[0].Right.Extent.Text))

    function Test-Shape {
        param([string]$Json)
        Set-StrictMode -Version Latest
        $auth = $Json | ConvertFrom-Json
        $requireAuth  = & $script:walk $auth @('globalValidation', 'requireAuthentication')
        $unauthAction = & $script:walk $auth @('globalValidation', 'unauthenticatedClientAction')
        $aadEnabled   = & $script:walk $auth @('identityProviders', 'azureActiveDirectory', 'enabled')
        [pscustomobject]@{
            Refuses      = ($requireAuth -ne $true -or $unauthAction -ne 'Return401' -or $aadEnabled -ne $true)
            RequireAuth  = $requireAuth
            UnauthAction = $unauthAction
            AadEnabled   = $aadEnabled
        }
    }
}

Describe 'AUTHREAD-1: the gate reads an answer it cannot predict the shape of' {

    It 'the shipped script carries the walker this test runs' {
        $script:walk | Should -BeOfType ([scriptblock])
    }

    It 'THE SHAPE THAT CRASHED IT now refuses, under strict mode' {
        # No globalValidation at all - what the platform actually answered.
        $r = Test-Shape '{"identityProviders":{"azureActiveDirectory":{"enabled":true}}}'
        $r.Refuses | Should -BeTrue
        $r.RequireAuth | Should -BeNullOrEmpty
    }

    It 'an empty object refuses rather than throwing' {
        # -not $auth is FALSE for an empty PSCustomObject, so the old guard let
        # this through to the property read.
        (Test-Shape '{}').Refuses | Should -BeTrue
    }

    It 'sign-in genuinely off still refuses' {
        $r = Test-Shape '{"globalValidation":{"requireAuthentication":false,"unauthenticatedClientAction":"AllowAnonymous"},"identityProviders":{"azureActiveDirectory":{"enabled":false}}}'
        $r.Refuses | Should -BeTrue
        $r.RequireAuth | Should -BeFalse
    }

    It 'and the correct answer publishes' {
        # Taken from the live platform on 2026-09-09.
        $r = Test-Shape '{"globalValidation":{"requireAuthentication":true,"unauthenticatedClientAction":"Return401"},"identityProviders":{"azureActiveDirectory":{"enabled":true}}}'
        $r.Refuses | Should -BeFalse
    }

    It 'a value that is absent is NOT the same as a value that is off' {
        # 'not reported' means the platform did not answer. Reading that as
        # 'off' sends a person to fix a setting that may be correct.
        $script:source | Should -Match "'not reported'"
        $script:source | Should -Match "not the same as 'off'"
    }

    It 'the comparison is explicit, so a missing value cannot read as a pass' {
        # -not $null is TRUE, which is right by luck. -ne $true is right by
        # construction, and survives a value that is a string or a number.
        $script:source | Should -Match '\$requireAuth -ne \$true'
        $script:source | Should -Match '\$aadEnabled -ne \$true'
    }

    It 'and a directory call that fails does not become an empty pass' {
        # INSTALL-THROTTLE-RETRY-1: a failed read returns nothing (-AllowFailure),
        # so the gate below refuses; a throttle on every try stops the publish.
        $script:source | Should -Match "\`$authJson = Invoke-VmfAzStep -Step '[^']+' -AllowFailure -Command \{"
    }
}
