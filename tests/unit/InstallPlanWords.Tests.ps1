#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# INSTALL-PLAN-WORDS-1 (2026-11-12): the hosting plan choice names the
# plans in Azure's own terms, and nothing more. The old words ("Free costs
# nothing, and it is slow. Basic costs money, and it is fast.") came from load
# times measured before the speed fixes. A first rewrite gave prices, lab
# figures and reasons to choose Basic; it was rejected as a wall of text with
# too much cost focus, and the exact sentences pinned below were approved.
#
# So each place says the same few sentences: the install question, the
# template descriptions, the manual. A price lives on Microsoft's pricing
# pages, linked from the costs page - never a figure, a lab number or a region.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:manual = Join-Path $script:repoRoot 'docs' 'manual'

    function Get-PlanSection {
        param([string]$Text, [string]$Pattern, [string]$Name)
        $m = [regex]::Match($Text, $Pattern)
        if (-not $m.Success) { throw "INSTALL-PLAN-WORDS-1: the plan text '$Name' was not found." }
        # A template description wraps its lines; a sentence is still a sentence.
        $m.Value -replace '\s+', ' '
    }

    $script:pre = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1') -Raw
    $script:main = Get-Content (Join-Path $script:repoRoot 'infra' 'main.bicep') -Raw
    $script:platform = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
    $azure = Get-Content (Join-Path $script:repoRoot 'azure.yaml') -Raw
    $choices = Get-Content (Join-Path $script:manual 'install' 'choices.md') -Raw
    $before = Get-Content (Join-Path $script:manual 'install' 'before-you-install.md') -Raw
    $script:costs = Get-Content (Join-Path $script:manual 'reference' 'costs.md') -Raw
    $steps = Get-Content (Join-Path $script:manual 'install' 'step-by-step.md') -Raw
    $signIn = Get-Content (Join-Path $script:manual 'use' 'sign-in.md') -Raw

    # Each plan text, cut to the part that is about the hosting plan. The
    # question block of step-by-step.md keeps its line breaks, to count lines.
    $script:stepsBlock = [regex]::Match($steps, '(?s)```\n(?:(?!```).)*?Choose the hosting plan(?:(?!```).)*```').Value
    $script:plan = [ordered]@{
        prompt   = Get-PlanSection $script:pre "(?s)Read-VmfChoice -Name 'VMF_HOSTING_PLAN'.*?Write-Host" 'install question'
        main     = Get-PlanSection $script:main "(?s)@description\('''WARM-1: ONE hosting choice.*?'''\)\s*param hostingPlan" 'main.bicep description'
        platform = Get-PlanSection $script:platform "(?s)@description\('''WARM-1: ONE choice covers.*?'''\)\s*param hostingPlan" 'platform.bicep description'
        azure    = Get-PlanSection $azure '(?s)The hosting plan is still a parameter.*?(?=\n#\s*\n)' 'azure.yaml comment'
        choices  = Get-PlanSection $choices '(?s)## Choice 1:.*?(?=## Choice 2:)' 'choices.md, Choice 1'
        before   = Get-PlanSection $before '(?s)## What it costs.*?(?=\n## )' 'before-you-install.md, What it costs'
        costs    = Get-PlanSection $script:costs '(?s)## What the install creates.*?(?=\n## )' 'costs.md, What the install creates'
        steps    = Get-PlanSection $steps '(?s)```\n(?:(?!```).)*?Choose the hosting plan(?:(?!```).)*```' 'step-by-step.md, the question'
        signIn   = Get-PlanSection $signIn '(?s)## If the wizard says the service did not answer.*?(?=<!-- next:begin -->)' 'sign-in.md, did not answer'
    }
    $script:mainParams = Get-Content (Join-Path $script:repoRoot 'infra' 'main.parameters.json') -Raw | ConvertFrom-Json

    # The approved sentences.
    $script:question = 'Choose the hosting plan for the dashboard and the service'
    $script:answerFree = 'Free: App Service Free (F1) for the dashboard, Azure Functions Consumption (Y1) for the service.'
    $script:answerBasic = 'Basic: one App Service Basic (B1) plan for both, with Always On.'
    $script:choicesText = 'Free uses App Service Free (F1) for the dashboard and Azure Functions Consumption (Y1) for the service. Basic uses one App Service Basic (B1) plan for both, with Always On. Free is the default.'
    $script:beforeText = 'The install asks you to choose a hosting plan: Free or Basic (see the next page). See [Costs](../reference/costs.md).'
    # MANUAL-REVIEW-1: the page did not try again on its own. Only the wizard
    # says the service did not answer, and it asks the person to try again
    # (wizard.js, UX.slow).
    $script:signInText = 'On the Free plan, Azure can stop the service when nobody uses it. The service starts again on the next request. If a step of the wizard says **The service did not answer. Try again.**, wait a moment, then do the step again.'
}

Describe 'INSTALL-PLAN-WORDS-1: the hosting plan is named in Azure terms, with the same sentences everywhere' {

    It 'every plan text is found' {
        foreach ($k in $script:plan.Keys) { $script:plan[$k] | Should -Not -BeNullOrEmpty -Because "$k is a plan text" }
    }

    It 'the install question is the approved question and the two approved answers, with no help lines' {
        $script:plan.prompt | Should -Match ([regex]::Escape("-Question '$($script:question)'"))
        $script:plan.prompt | Should -Match ([regex]::Escape("'Free|$($script:answerFree)'"))
        $script:plan.prompt | Should -Match ([regex]::Escape("'Basic|$($script:answerBasic)'"))
        $script:plan.prompt | Should -Not -Match '-Help\b' -Because 'every line above the question was removed'
    }

    It 'the manual shows the same question and answers, and nothing more' {
        $script:plan.steps | Should -Match ([regex]::Escape($script:question))
        $script:plan.steps | Should -Match ([regex]::Escape("1) $($script:answerFree) (default)"))
        $script:plan.steps | Should -Match ([regex]::Escape("2) $($script:answerBasic)"))
        # The block holds the question, the two answers and the prompt line.
        $lines = @($script:stepsBlock -split "`n" | Where-Object { $_.Trim() -and $_.Trim() -ne '```' })
        $lines.Count | Should -Be 4
    }

    It 'the template descriptions and the azure.yaml comment use the same two answer sentences' {
        foreach ($k in 'main', 'platform', 'azure') {
            $script:plan[$k] | Should -Match ([regex]::Escape($script:answerFree)) -Because "$k describes Free with the answer sentence"
            $script:plan[$k] | Should -Match ([regex]::Escape($script:answerBasic)) -Because "$k describes Basic with the answer sentence"
        }
    }

    It 'choices.md says the plans in one paragraph, and only that' {
        $script:plan.choices | Should -Match ([regex]::Escape($script:choicesText))
        foreach ($gone in 'daily limit', 'platform logs', 'one instance', 'processor time', 'Choose Basic', 'no monthly plan charge') {
            $script:plan.choices | Should -Not -Match $gone -Because 'all the plan text was replaced with one paragraph'
        }
    }

    It 'the costs page names each resource the install creates, with a link to Microsoft''s pricing page' {
        $rows = [ordered]@{
            'Azure Container Registry, Basic'                  = '[Container Registry pricing](https://azure.microsoft.com/pricing/details/container-registry/)'
            'Storage account (the run store)'                  = '[Blob Storage pricing](https://azure.microsoft.com/pricing/details/storage/blobs/)'
            'Log Analytics workspace and Application Insights' = '[Azure Monitor pricing](https://azure.microsoft.com/pricing/details/monitor/)'
            'Hosting plan: Free (F1 and Y1) or Basic (B1)'     = '[App Service pricing](https://azure.microsoft.com/pricing/details/app-service/windows/) and [Azure Functions pricing](https://azure.microsoft.com/pricing/details/functions/)'
            'Container Apps environment and two Container Apps jobs' = '[Container Apps pricing](https://azure.microsoft.com/pricing/details/container-apps/)'
        }
        foreach ($r in $rows.Keys) {
            $script:costs | Should -Match ([regex]::Escape("| $r | $($rows[$r]) |")) -Because "the costs page has the row for $r"
        }
        $script:costs | Should -Match '(?m)^Everything runs in your subscription\. Azure bills each resource at its list price\.$'
    }

    It 'the costs page has the three headings, the migration rows and the line for what keeps billing' {
        $heads = @([regex]::Matches($script:costs, '(?m)^## .+$') | ForEach-Object { $_.Value.Trim() })
        ($heads -join ' / ') | Should -Be '## What the install creates / ## What a migration adds / ## What keeps billing'
        foreach ($row in @(
                '| Two safety copies of each machine. A copy is a snapshot of each disk. A retry from the first step makes two new copies. | Until the daily cleanup deletes them after the retention of the wave |',
                '| A rollback disk for each disk of the machine, made from the first safety copy | During the move. Then the product deletes each rollback disk that it did not use. |',
                '| On-demand capacity reservation, if chosen | From the moment Azure holds it, used or not, until every machine of the wave has ended and the product releases it, or until you select Release. |',
                '| A Container Apps job | While a wave runs |',
                '| Each machine | At the price of its target size after the move |')) {
            $script:costs | Should -Match ([regex]::Escape($row))
        }
        $migration = [regex]::Match($script:costs, '(?s)## What a migration adds.*?(?=\n## )').Value
        @($migration -split "`n" | Where-Object { $_ -match '^\| ' -and $_ -notmatch '^\| (Resource|---)' }).Count | Should -Be 5
        $script:costs | Should -Match '(?m)^An on-demand capacity reservation for a wave that does not run\. Release it on the Quota and on-demand capacity reservations card of the migration\.$'
    }

    It 'no manual page states a dollar figure or cents for what the product costs' {
        $pages = Get-ChildItem $script:manual -Recurse -Filter *.md | Where-Object { $_.FullName -notmatch '[\\/]vendor[\\/]' }
        $hits = @($pages | Select-String -Pattern '\$\s?\d|\bcents?\b|(?i)\bcosts? about\b' | ForEach-Object { "$($_.Path):$($_.LineNumber)" })
        $hits | Should -BeNullOrEmpty
    }

    It 'before-you-install.md and sign-in.md use the approved sentences' {
        $script:plan.before | Should -Match ([regex]::Escape($script:beforeText))
        $script:plan.signIn | Should -Match ([regex]::Escape($script:signInText))
    }

    It 'no plan text says slow or fast, states a plan price or a lab figure, or names a region' {
        foreach ($k in $script:plan.Keys) {
            $t = $script:plan[$k]
            $t | Should -Not -Match '(?i)\b(slow|slower|slowly|fast|faster)\b' -Because "$k names the plans, not their speed"
            $t | Should -Not -Match '\$55|\$110|54\.75' -Because "$k states no plan price"
            $t | Should -Not -Match '(?i)\bGB-s\b|\b\d+ (to \d+ )?seconds\b|\babout a minute\b' -Because "$k states no lab figure"
            $t | Should -Not -Match '(?i)\b(central|east|west|north|south)\s?(us|europe|asia|india)\d?\b|\b(centralus|eastus2?|westus\d?|westeurope|northeurope|uksouth)\b' -Because "$k names no region"
        }
    }

    It 'the free plan stays the default in every place that sets it' {
        $script:pre | Should -Match "Read-VmfChoice -Name 'VMF_HOSTING_PLAN' -Default 'Free'"
        $script:main | Should -Match "param hostingPlan string = 'Free'"
        $script:platform | Should -Match "param hostingPlan string = 'Free'"
        $script:mainParams.parameters.hostingPlan.value | Should -Be '${VMF_HOSTING_PLAN=Free}'
    }
}
