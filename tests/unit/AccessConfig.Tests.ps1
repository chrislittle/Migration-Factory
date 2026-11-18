#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# ACCESS-HALF-1: the config carries BOTH identities, and the page reads the
# same key the deploy writes.
#
# THE DEFECT. The product has two identities that need reach over a customer's
# machines. The engine changes them; the web service READS them, and every
# list the dashboard shows comes from the web service. `dashboard.config.json`
# named only the engine, so the Access page could not have granted the web
# service even if it had tried - and it did not try. A scope granted in the app
# left every list in the product empty while the page reported the place as
# covered.
#
# THE HALF THAT HAS NO SHAPE. A key name is a contract between a PowerShell
# script that writes a file and a browser that reads it, and nothing checks it.
# Rename one side and the page silently reads `undefined`, which is falsy,
# which is exactly the state this item is fixing. A mutation proved it: taking
# the value out of the deploy left every other check green.

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:deploy   = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
    $script:access   = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.html'))
    $script:sample   = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'dashboard.sample.config.json') -Raw |
                         ConvertFrom-Json
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
}

Describe 'ACCESS-HALF-1: the config names both halves of the product' {

    It 'the sample declares the web service identity' {
        $script:sample.PSObject.Properties.Name | Should -Contain 'webServicePrincipalId'
    }

    It 'and still declares the engine, so this did not replace one with the other' {
        $script:sample.PSObject.Properties.Name | Should -Contain 'enginePrincipalId'
    }

    It 'the deploy writes it into the config it publishes' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1')
        $code | Should -Match 'webServicePrincipalId\s*=\s*\$webServicePrincipalId'
    }

    It 'and reads it from the web service that is actually deployed' {
        # Not invented, not defaulted: the system-assigned identity of the
        # function app this install published.
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1')
        $code | Should -Match '\$webServicePrincipalId\s*=\s*if \(\$facadeSite\)'
        $code | Should -Match '\$facadeSite\.identity\.principalId'
    }

    It 'and says what it costs when there is no identity to write' {
        # A blank here is not cosmetic - it is the page unable to grant half
        # the product. A warning that does not say so is a warning nobody acts
        # on.
        $script:deploy | Should -Match '(?s)if \(-not \$webServicePrincipalId\).{0,400}lists in the product would stay empty'
    }
}

Describe 'ACCESS-HALF-1: the page reads the key the deploy writes' {

    It 'the grant asks the config for the web service' {
        $script:access | Should -Match 'cfg\.webServicePrincipalId'
    }

    It 'and the two sides spell it the same way' {
        # THE POINT OF THIS FILE. One side is PowerShell, the other a browser,
        # and a rename on either is silent: the page reads undefined, treats it
        # as "no web service", and grants half - which is the defect.
        $written = [regex]::Matches($script:deploy, '(?m)^\s*(\w+)\s*=\s*\$webServicePrincipalId') |
                     ForEach-Object { $_.Groups[1].Value }
        @($written) | Should -Contain 'webServicePrincipalId'
        $read = [regex]::Matches($script:access, 'cfg\.(\w+)') | ForEach-Object { $_.Groups[1].Value }
        @($read) | Should -Contain 'webServicePrincipalId'
    }

    It 'and the sample declares every identity key the page reads from the config' {
        # A page that reads a key nothing publishes is a page that silently
        # does less than it says.
        $declared = @($script:sample.PSObject.Properties.Name)
        foreach ($key in 'enginePrincipalId', 'webServicePrincipalId', 'assessRoleId', 'migrateRoleId') {
            $script:access | Should -Match "cfg\.$key|vmfRoleId" -Because "$key is a config key"
            $declared | Should -Contain $key
        }
    }
}

Describe 'ACCESS-HALF-1: the install''s grant and the Admin page''s grant are identical' {

    # docs/manual/install/after-install.md, about the command line route, said:
    #
    #     "The grant is identical to the one the page makes"
    #
    # THAT SENTENCE WAS FALSE FOR AS LONG AS THIS DEFECT EXISTED. The command
    # granted both halves of the product; the page granted the engine. An
    # operator who read that line and used either route believed they had the
    # same result, and one of the two left every list in the product empty.
    #
    # MANUAL-REVIEW-1 removed the command line route from the manual (hard
    # rule 12: a person gives access on the Admin page). The install still
    # gives its first grant through Grant-VmfAccess.ps1 (postprovision.ps1),
    # so the two grants must still be the same.

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:manual = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'after-install.md') -Raw
        $script:grant  = Get-Content (Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1') -Raw
    }

    It 'the install gives its grant through the command, so the two routes exist' {
        $post = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1')
        $post | Should -Match "'tools' 'Grant-VmfAccess\.ps1'"
        $script:manual | Should -Not -Match 'Grant-VmfAccess' -Because 'the manual gives the Admin page, never a command (hard rule 12)'
    }

    It 'wherever the command grants the ENGINE a scope, it grants the web service that scope too' {
        # A mutation found the first version of this too loose: the command
        # grants the web service on TWO paths - the assess scope and the
        # migrate scope - so deleting one left the other and a bare match still
        # passed. The rule is per SCOPE, so ask it per scope.
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1')
        $engineScopes = @([regex]::Matches($code, 'Grant-Role -PrincipalId \$engineMi[^\r\n]*-Scope (\$\w+)') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        @($engineScopes).Count | Should -BeGreaterThan 1 -Because 'the engine is granted at more than one kind of scope'
        $facadeScopes = @([regex]::Matches($code, 'Grant-Role -PrincipalId \$facadeMi[^\r\n]*-Scope (\$\w+)') |
            ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        foreach ($scope in $engineScopes) {
            @($facadeScopes) | Should -Contain $scope -Because "the web service must reach $scope as well, or the product reaches it with one half"
        }
    }

    It 'and so does the page' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.html')
        $code | Should -Match 'ids\.enginePrincipalId'
        $code | Should -Match 'ids\.webServicePrincipalId'
    }

    It 'and neither gives the web service a role that changes a machine' {
        # It reads. The migration role is the engine's alone, on both routes.
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1')
        $code | Should -Not -Match "Grant-Role -PrincipalId \`$facadeMi -RoleName 'VMF Migration'"
        $page = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.html')
        $plan = [regex]::Match($page, '(?s)function grantPlan\(level, ids\) \{.*?\n\}').Value
        $plan | Should -Not -BeNullOrEmpty
        $plan | Should -Match "who: 'service'[\s\S]{0,120}roleDefinitionId: ids\.assessRoleId"
    }
}
