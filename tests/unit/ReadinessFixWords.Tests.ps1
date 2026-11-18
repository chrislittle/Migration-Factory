#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# READINESS-FIX-WORDS-1 - every readiness blocker says what to do.
#
# The question (2026-11-10): does every check that fails stop azd and say
# what to do? It stopped on each blocker, but several gave no action: a
# region with no Container Apps or no Consumption profile, and three full
# limits (Container Apps environments, storage accounts, F1 plans). Two more -
# azd not found, PowerShell older than 7 - could never be true, because azd
# runs this script in pwsh; they are removed. The last three shared one detail with the 'ok'
# result through $(if ... 'ok' else 'blocker'), so the words could not differ.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:readyPath = Join-Path $script:repoRoot 'infra' 'hooks' 'Test-VmfReadiness.ps1'
    $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:readyPath, [ref]$null, [ref]$null)
    $script:addChecks = @($script:ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Add-Check'
    }, $true))
    # The words that make a detail an instruction, from docs/manual/install/if-it-fails.md.
    $script:action = '(?i)\b(Install|Request a quota increase|Choose another region|Ask a subscription Owner|Repair it)\b|\bRun: |\$retry|\$otherRegion'
}

Describe 'READINESS-FIX-WORDS-1: every blocker says what to do' {
    It 'found the Add-Check calls and their blockers, or none of this proves anything' {
        $script:addChecks.Count | Should -BeGreaterThan 15
        @($script:addChecks | Where-Object { $_.CommandElements[2].Extent.Text -eq "'blocker'" }).Count | Should -BeGreaterOrEqual 10
    }

    It 'no result is chosen inside the call, so a blocker never shares the ok words' {
        $shared = @($script:addChecks | Where-Object { $_.CommandElements[2].Extent.Text -match 'blocker' -and $_.CommandElements[2].Extent.Text -ne "'blocker'" })
        @($shared | ForEach-Object { $_.Extent.Text }) | Should -BeNullOrEmpty
    }

    It 'every blocker detail holds an action' {
        $silent = foreach ($call in $script:addChecks) {
            if ($call.CommandElements[2].Extent.Text -ne "'blocker'") { continue }
            $detail = ($call.CommandElements | Select-Object -Skip 3 | ForEach-Object { $_.Extent.Text }) -join ' '
            if ($detail -notmatch $script:action) { $call.Extent.Text }
        }
        @($silent) | Should -BeNullOrEmpty
    }

    It 'the shared endings name azd up and the region setting' {
        $code = Get-Content $script:readyPath -Raw
        $code | Should -Match "\`$retry = ', then run azd up again\.'"
        $code | Should -Match "\`$otherRegion = 'Choose another region: azd env set AZURE_LOCATION <region>, then run azd up again\.'"
    }

    It 'checks nothing that cannot fail: azd runs this script, in PowerShell 7' {
        # azd runs this script, so "azd not found" can never be true (2026-11-10).
        foreach ($tool in 'Azure Developer CLI', 'PowerShell') {
            $calls = @($script:addChecks | Where-Object { $_.CommandElements[1].Extent.Text -eq "'$tool'" })
            $calls.Count | Should -Be 1 -Because "the $tool row stays, for its version"
            $calls[0].CommandElements[2].Extent.Text | Should -Be "'ok'"
        }
        (Get-Content (Join-Path $script:repoRoot 'azure.yaml') -Raw) | Should -Match '(?s)preprovision:\s*shell: pwsh'
    }

    It 'says a version as a fact, never as too old' {
        $said = foreach ($call in $script:addChecks) { ($call.CommandElements | Select-Object -Skip 3 | ForEach-Object { $_.Extent.Text }) -join ' ' }
        @($said | Where-Object { $_ -match '(?i)too (old|new)' }) | Should -BeNullOrEmpty
        @($said | Where-Object { $_ -match 'version 2\.61\.0 or a later version' }).Count | Should -Be 2
    }

    It 'names no backlog item to the operator' {
        $said = foreach ($call in $script:addChecks) { ($call.CommandElements | Select-Object -Skip 3 | ForEach-Object { $_.Extent.Text }) -join ' ' }
        @($said | Where-Object { $_ -match '\b[A-Z]{2,}(-[A-Z0-9]+)*-\d+\b' }) | Should -BeNullOrEmpty
    }

    It 'the manual lists every check that can block, with what to do' {
        $page = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'if-it-fails.md') -Raw
        foreach ($check in 'Region offers Container Apps', 'Region offers workload profiles', 'Container Apps environments in the region',
                           'Storage accounts in the region', 'Hosting plans') {
            $page | Should -Match ('\| ' + [regex]::Escape($check) + ' \|')
        }
        $page | Should -Match 'azd env set VMF_HOSTING_PLAN'
    }
}

Describe 'READINESS-FIX-WORDS-1: room is judged per hosting plan answer' {
    # The check assumed F1, but the hosting plan is chosen later and can be
    # Basic (2026-11-10). Free = a Free plan (F1) AND a Consumption plan (Y1);
    # Basic = one Basic plan (B1) - infra/platform.bicep.
    BeforeAll {
        $found = @($script:ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-VmfHostingPlanRoom'
        }, $true))
        if ($found.Count -ne 1) { throw "expected one Get-VmfHostingPlanRoom, found $($found.Count)" }
        $script:room = & ([scriptblock]::Create("function Get-VmfHostingPlanRoom $($found[0].Body.Extent.Text)`n`${function:Get-VmfHostingPlanRoom}"))
        function script:Plan { param($Limit, $Used) [pscustomobject]@{ Limit = $Limit; Used = $Used } }
        function script:RoomOf { param($Rows, $Choice) @($Rows | Where-Object { $_.Choice -eq $Choice })[0] }
    }

    It 'the template still builds Free as F1 plus Y1 and Basic as B1, or these rows judge the wrong plans' {
        $bicep = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
        $bicep | Should -Match "skuName: warm \? 'B1' : 'F1'"
        $bicep | Should -Match "skuName: 'Y1'"
    }

    It 'room for everything: both answers ok' {
        $rows = @(& $script:room -Plans @{ F1 = (Plan 33 0); Y1 = (Plan 3 0); B1 = (Plan 31 0) } -Location 'westus3')
        $rows.Choice | Should -Be @('Free', 'Basic')
        $rows.Result | Should -Be @('ok', 'ok')
    }

    It 'Consumption plans full: Free cannot be chosen, Basic can - and nothing blocks yet' {
        $rows = @(& $script:room -Plans @{ F1 = (Plan 33 0); Y1 = (Plan 3 3); B1 = (Plan 31 0) } -Location 'westus3')
        (RoomOf $rows 'Free').Result | Should -Be 'warn'
        (RoomOf $rows 'Free').Detail | Should -Match 'the limit for the Consumption plan \(Y1\) is 3, and 3 are in use'
        (RoomOf $rows 'Free').Detail | Should -Not -Match 'Free plan \(F1\) is'
        (RoomOf $rows 'Basic').Result | Should -Be 'ok'
    }

    It 'Free plans full: Free cannot be chosen, and Basic does not care about F1' {
        $rows = @(& $script:room -Plans @{ F1 = (Plan 33 33); Y1 = (Plan 3 0); B1 = (Plan 31 0) } -Location 'westus3')
        (RoomOf $rows 'Free').Result | Should -Be 'warn'
        (RoomOf $rows 'Basic').Result | Should -Be 'ok'
    }

    It 'a plan the resource group already holds needs no room (a second azd up)' {
        $rows = @(& $script:room -Plans @{ F1 = (Plan 33 33); Y1 = (Plan 3 3); B1 = (Plan 31 31) } -Have @('F1', 'Y1') -Location 'westus3')
        (RoomOf $rows 'Free').Result | Should -Be 'ok'
        (RoomOf $rows 'Free').Detail | Should -Match 'already has'
        (RoomOf $rows 'Basic').Result | Should -Be 'warn'
    }

    It 'a plan type the region does not report is unknown, never a pass or a stop' {
        $rows = @(& $script:room -Plans @{ F1 = (Plan 33 0); B1 = (Plan 31 0) } -Location 'westus3')
        (RoomOf $rows 'Free').Result | Should -Be 'unknown'
        (RoomOf $rows 'Free').Detail | Should -Match 'Consumption plan \(Y1\)'
    }

    It 'the readiness check blocks only when every answer has no room' {
        $code = Get-Content $script:readyPath -Raw
        $code | Should -Match "Where-Object \{ \`$_\.Result -eq 'warn' \}\)\.Count -eq \`$rooms\.Count"
        $code | Should -Match 'if \(\$ResourceGroup\)' -Because 'an empty group would list every plan in the subscription'
    }

    It 'the install refuses an answer whose row has no room, after the question and before anything is made' {
        $pre = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1') -Raw
        $pre | Should -Match "-ResourceGroup \`$rg\)"
        $at = $pre.IndexOf("Write-Host `"   hosting plan: `$plan`"")
        $refuse = $pre.IndexOf('"Hosting plan: $plan"')
        $at | Should -BeGreaterThan 0
        $refuse | Should -BeGreaterThan $at
        $pre | Should -Match 'azd env set VMF_HOSTING_PLAN \$\{other\}'
    }
}
