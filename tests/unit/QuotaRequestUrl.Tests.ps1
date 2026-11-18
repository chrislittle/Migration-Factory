#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# QUOTA-REQUEST-URL-1, 2026-11-16 (final lab, step 3.5).
#
# Request a quota increase never reached Azure's quota API. The path was built
# as "/providers/Microsoft.Quota/quotas/$Family?api-version=2023-02-01", and
# PowerShell 7 allows '?' in a variable name: it read '$Family?api' as ONE
# undefined variable, so the path became ".../quotas/-version=2023-02-01" and
# Azure answered HTTP 400 MissingApiVersionParameter. Every earlier test mocked
# Request-VmfQuotaIncrease itself or never read the path it built.
#
# Two checks:
#   1. The exact path and payload Request-VmfQuotaIncrease sends.
#   2. The class: no PowerShell file in src, infra, tools, lab or tests has a
#      variable written without braces whose name holds '?'. The PowerShell
#      parser decides, so a comment or a single-quoted string never counts.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # Every variable in a parsed script whose name holds '?' and was written
    # without braces: '$name?' in a string, or anywhere else. '${name}?' is the
    # correct form and is not returned, and neither is the automatic '$?'.
    function Global:Find-QruQuestionVariable {
        param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
        @($Ast.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
                    $node.VariablePath.UserPath.Contains('?') -and
                    $node.VariablePath.UserPath -ne '?' -and
                    -not $node.Extent.Text.StartsWith('${')
                }, $true))
    }
}

AfterAll {
    Remove-Item Function:\Find-QruQuestionVariable -ErrorAction SilentlyContinue
}

Describe 'QUOTA-REQUEST-URL-1: Request-VmfQuotaIncrease sends the quota path Azure accepts' {
    It 'puts the family and ?api-version=2023-02-01 in the path, and the limit in the payload' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 202; Content = '{}' } }

        InModuleScope VmMigrationFactory {
            Request-VmfQuotaIncrease -SubscriptionId '00000000-0000-0000-0000-000000000000' -Location 'centralus' `
                -Family 'standardDASv5Family' -NewLimit 4 | Out-Null
        }

        Should -Invoke -ModuleName VmMigrationFactory Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PUT' -and
            $Path -ceq ('/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Compute/locations/centralus' +
                '/providers/Microsoft.Quota/quotas/standardDASv5Family?api-version=2023-02-01')
        }
        Should -Invoke -ModuleName VmMigrationFactory Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter {
            $body = $Payload | ConvertFrom-Json
            $body.properties.name.value -ceq 'standardDASv5Family' -and
            $body.properties.limit.limitObjectType -ceq 'LimitValue' -and
            $body.properties.limit.value -eq 4
        }
    }

    It 'sends the regional resource name cores the same way' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }

        InModuleScope VmMigrationFactory {
            Request-VmfQuotaIncrease -SubscriptionId '00000000-0000-0000-0000-000000000000' -Location 'westus3' `
                -Family 'cores' -NewLimit 20 | Out-Null
        }

        Should -Invoke -ModuleName VmMigrationFactory Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter {
            $Path -ceq ('/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Compute/locations/westus3' +
                '/providers/Microsoft.Quota/quotas/cores?api-version=2023-02-01')
        }
    }
}

Describe 'QUOTA-REQUEST-URL-1: no variable name takes a ? by accident' {
    It 'finds the defect on the line as it was' {
        $old = '$path = "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Location" +' + [Environment]::NewLine +
               '        "/providers/Microsoft.Quota/quotas/$Family?api-version=2023-02-01"'
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($old, [ref]$null, [ref]$null)
        $found = Find-QruQuestionVariable -Ast $ast
        $found.Count | Should -Be 1
        $found[0].Extent.Text | Should -BeExactly '$Family?api'
    }

    It 'does not find the braced form, a braced name that holds a ?, $?, a comment, or a single-quoted string' {
        $good = @(
            '$path = "/quotas/${Family}?api-version=2023-02-01"'
            '# "/quotas/$Family?api-version=2023-02-01"'
            '$x = ''/quotas/$Family?api-version=2023-02-01'''
            '$y = $a ? $b : $c'
            '$z = "${odd?name}"'
            'if (-not $?) { }'
        ) -join [Environment]::NewLine
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($good, [ref]$null, [ref]$null)
        (Find-QruQuestionVariable -Ast $ast).Count | Should -Be 0
    }

    It 'finds it in a here-string and in a bare command argument' {
        $bad = @(
            '$a = @"'
            '/quotas/$Family?api-version=1'
            '"@'
            'Invoke-Thing -Path /quotas/$Family?api-version=1'
        ) -join [Environment]::NewLine
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($bad, [ref]$null, [ref]$null)
        (Find-QruQuestionVariable -Ast $ast).Count | Should -Be 2
    }

    It 'holds for every PowerShell file in src, infra, tools, lab and tests' {
        $files = foreach ($dir in 'src', 'infra', 'tools', 'lab', 'tests') {
            $full = Join-Path $script:repoRoot $dir
            if (Test-Path -LiteralPath $full) {
                Get-ChildItem -LiteralPath $full -Recurse -File -Include *.ps1, *.psm1, *.psd1
            }
        }
        @($files).Count | Should -BeGreaterThan 100
        $hits = foreach ($file in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            foreach ($node in (Find-QruQuestionVariable -Ast $ast)) {
                '{0}:{1}: {2} (write ${{name}} before a ?)' -f
                    [System.IO.Path]::GetRelativePath($script:repoRoot, $file.FullName), $node.Extent.StartLineNumber, $node.Extent.Text
            }
        }
        @($hits) | Should -BeNullOrEmpty -Because ($hits -join '; ')
    }
}
