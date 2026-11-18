#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PIPELINE-LATER-1, 2026-11-02: every pipeline model moves past 1.0, and
# azd does not ask about one. An update is azd up after the local copy of the
# repository is updated. Manual pages on pipelines move out of the manual and
# are kept for later.
#
# So a 1.0 install has ONE update model, and nothing of the other is left
# dormant: no question, no parameter, no grant, no setting on the service, no
# line in the About dialog, and no page in the manual that ships with the
# dashboard. The page is kept, outside the manual, for DIST-2.
#
# Every scan of code here reads the CODE (Get-VmfCodeOnly): a comment that
# explains what was removed must not be able to pass or fail a check.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:infra = Join-Path $script:repoRoot 'infra'
    $script:manual = Join-Path $script:repoRoot 'docs' 'manual'
    $script:later = Join-Path $script:repoRoot 'docs' 'later' 'pipeline'
    $script:code = @{
        preprovision = Get-VmfCodeOnly -Path (Join-Path $script:infra 'hooks' 'preprovision.ps1')
        hooks        = Get-VmfCodeOnly -Path (Join-Path $script:infra 'hooks' 'AzdHooks.ps1')
        deploy       = Get-VmfCodeOnly -Path (Join-Path $script:infra 'deploy.ps1')
        main         = Get-VmfCodeOnly -Path (Join-Path $script:infra 'main.bicep') -Language CStyle
        platform     = Get-VmfCodeOnly -Path (Join-Path $script:infra 'platform.bicep') -Language CStyle
        facade       = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        help         = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Language CStyle
    }
    $script:parameters = Get-Content (Join-Path $script:infra 'main.parameters.json') -Raw
    $script:manualPages = @(Get-ChildItem $script:manual -Recurse -File -Include '*.md', '*.html')
}

Describe 'PIPELINE-LATER-1: the install does not ask who runs updates' {

    It 'the decision page has no update question and no object id question' {
        $script:code.preprovision | Should -Not -Match 'VMF_UPDATE_MODEL'
        $script:code.preprovision | Should -Not -Match 'VMF_DEPLOY_PRINCIPAL_ID'
        $script:code.preprovision | Should -Not -Match '(?i)Who runs updates'
        $script:code.preprovision | Should -Not -Match '(?i)runs the update'
    }

    It 'the helpers only that question used are gone, not kept dormant' {
        # Read-VmfText asked for the object id, and -Consequential stopped an
        # unattended install from taking 'person' over a pipeline. Neither has
        # another caller.
        $script:code.hooks | Should -Not -Match 'function Read-VmfText\b'
        $script:code.hooks | Should -Not -Match 'Consequential'
        foreach ($f in Get-ChildItem (Join-Path $script:infra 'hooks') -Filter '*.ps1') {
            $c = Get-VmfCodeOnly -Path $f.FullName
            $c | Should -Not -Match 'Read-VmfText\b' -Because "$($f.Name) calls a helper that no longer exists"
            $c | Should -Not -Match '-Consequential' -Because "$($f.Name) passes a switch that no longer exists"
        }
    }

    It 'no install file names the update model or the deploy principal' {
        $files = @(Get-ChildItem $script:infra -Recurse -File -Include '*.ps1', '*.bicep', '*.json') +
                 @(Get-Item (Join-Path $script:repoRoot 'azure.yaml'))
        $files.Count | Should -BeGreaterThan 10 -Because 'the scan must find the install files, or it proves nothing'
        foreach ($f in $files) {
            $c = if ($f.Extension -eq '.ps1') { Get-VmfCodeOnly -Path $f.FullName }
                 elseif ($f.Extension -eq '.bicep') { Get-VmfCodeOnly -Path $f.FullName -Language CStyle }
                 else { Get-Content $f.FullName -Raw }
            $c | Should -Not -Match '(?i)VMF_UPDATE_MODEL|VMF_DEPLOY_PRINCIPAL|deployPrincipalId|updateModel' -Because "$($f.Name) still carries the update model"
        }
    }
}

Describe 'PIPELINE-LATER-1: the template grants nothing to a pipeline' {

    It 'has no deploy principal parameter, in the template, its parameters or the hand deploy' {
        $script:code.main | Should -Not -Match 'param deployPrincipalId'
        $script:code.platform | Should -Not -Match 'param deployPrincipalId'
        $script:parameters | Should -Not -Match 'deployPrincipalId|VMF_DEPLOY_PRINCIPAL_ID'
        $script:code.deploy | Should -Not -Match '(?i)DeployPrincipalId'
    }

    It 'every role assignment goes to one of the product''s own identities' {
        # The class, not the instance: a grant to any principal the template
        # does not create is a grant to somebody outside the product.
        $principals = @([regex]::Matches($script:code.platform, '(?m)^\s*principalId:\s*(?<who>\S+)') | ForEach-Object { $_.Groups['who'].Value })
        $principals.Count | Should -BeGreaterOrEqual 5 -Because 'the scan must find the grants, or it proves nothing'
        $own = @('engineIdentity.outputs.principalId', 'publishIdentity.outputs.principalId', 'facade.outputs.systemAssignedMIPrincipalId!')
        foreach ($who in $principals) {
            $who | Should -BeIn $own -Because 'a 1.0 install grants rights only to the identities it creates'
        }
    }

    It 'has no constrained role grant (CD-2 stage A) and no update model output' {
        $script:code.platform | Should -Not -Match 'roleRbacAdministrator|deployRoleCondition|pipelineRoles|conditionVersion'
        $script:code.platform | Should -Not -Match 'deployReader|deployRoleGrant|deployGrant'
        $script:code.main | Should -Not -Match 'output VMF_UPDATE_MODEL'
    }

    It 'keeps no role id that no grant uses' {
        # A role id left behind looks like a right somebody holds.
        foreach ($m in [regex]::Matches($script:code.platform, "(?m)^var (?<name>role\w+) = '")) {
            $name = $m.Groups['name'].Value
            ([regex]::Matches($script:code.platform, "\b$name\b")).Count | Should -BeGreaterThan 1 -Because "$name is declared and never used"
        }
    }
}

Describe 'PIPELINE-LATER-1: the service and the dashboard do not say an update model' {

    It 'the service reads no update model' {
        $script:code.facade | Should -Not -Match 'VMF_UPDATE_MODEL|VMF_DEPLOY_PRINCIPAL'
        $script:code.facade | Should -Not -Match 'updatedBy'
    }

    It 'and the publish removes the two settings from a site an older install left them on' {
        # The template merges the settings a site has now with its own
        # (facade-appsettings.bicep), so a setting the template stops stating
        # stays on the site. The publish retires such a setting, the same way
        # it retires the key-based storage connection (SEC-1).
        $publish = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Deploy-VmfFacade.ps1')
        $publish | Should -Match "\`$retiredModel = @\(\`$settings \| Where-Object \{ \`$_\.name -in @\('VMF_UPDATE_MODEL', 'VMF_DEPLOY_PRINCIPAL'\) \}"
        $publish | Should -Match '(?s)if \(\$retiredModel\.Count\) \{.*?az functionapp config appsettings delete -g \$ResourceGroup -n \$FunctionAppName --setting-names @\(\$retiredModel\.name\)'
    }

    It 'the About dialog has no update model line' {
        $script:code.help | Should -Not -Match 'updatedBy'
        $script:code.help | Should -Not -Match '(?i)runs the update'
    }
}

Describe 'PIPELINE-LATER-1: the manual gives one way to update' {

    It 'found the manual, or this proves nothing' {
        $script:manualPages.Count | Should -BeGreaterThan 40
    }

    It 'the pipeline page and its picture are out of the manual that ships' {
        Test-Path (Join-Path $script:manual 'install' 'pipeline.md') | Should -BeFalse
        Test-Path (Join-Path $script:manual 'images' 'pipeline-signin.svg') | Should -BeFalse
    }

    # PUBLIC-SYNC-1: docs/later does not ship to the public repository.
    It 'and kept for later, outside it' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'docs' 'later'))) {
        Test-Path (Join-Path $script:later 'pipeline.md') | Should -BeTrue
        Test-Path (Join-Path $script:later 'pipeline-signin.svg') | Should -BeTrue
        $page = Get-Content (Join-Path $script:later 'pipeline.md') -Raw
        $page | Should -Match '\(pipeline-signin\.svg\)' -Because 'the picture moved with the page'
        $page | Should -Match 'PIPELINE-LATER-1' -Because 'the page says why it is not in the manual'
    }

    It 'no page links to the pipeline page or its picture' {
        foreach ($f in $script:manualPages) {
            $t = Get-Content $f.FullName -Raw
            $t | Should -Not -Match 'pipeline\.md|pipeline-signin' -Because "$($f.Name) still links to the pipeline page"
        }
    }

    It 'no page names the update model, its question or its values' {
        foreach ($f in $script:manualPages) {
            $t = Get-Content $f.FullName -Raw
            $t | Should -Not -Match 'VMF_UPDATE_MODEL|VMF_DEPLOY_PRINCIPAL' -Because "$($f.Name) names a value the install no longer reads"
            $t | Should -Not -Match '(?i)Who runs updates|a pipeline runs the update|If a pipeline runs' -Because "$($f.Name) still offers the pipeline model"
        }
        (Get-Content (Join-Path $script:repoRoot 'README.md') -Raw) | Should -Not -Match '(?i)who runs updates' -Because 'the front page lists the questions the install asks'
    }

    It 'the install asks two questions, not three' {
        # The repository's front page and the install shortcut count them too.
        $front = @(Get-Item (Join-Path $script:repoRoot 'README.md'), (Join-Path $script:repoRoot 'docs' 'install.md'))
        foreach ($f in @($script:manualPages) + $front) {
            $t = Get-Content $f.FullName -Raw
            $t | Should -Not -Match '(?i)three (choices|questions)' -Because "$($f.Name) still counts the update question"
        }
        (Get-Content (Join-Path $script:manual 'install' 'choices.md') -Raw) | Should -Match '(?i)two questions'
    }

    It 'the renumbered machines choice says the default the install really takes' {
        # Rewriting the page from three choices to two met two false lines on
        # the same choice: "its default is none" and "scanning is the
        # default". FIRSTSCOPE-1 made the default migrate.
        $script:code.preprovision | Should -Match "\`$default = 'migrate'"
        $choices = Get-Content (Join-Path $script:manual 'install' 'choices.md') -Raw
        $choices | Should -Match '(?i)The default is to scan and migrate'
        $choices | Should -Not -Match '(?i)its default is none|scanning is the default|Choice 3'
    }

    It 'the update page says the one way: get the source, then azd up' {
        $update = Get-Content (Join-Path $script:manual 'install' 'update.md') -Raw
        $update | Should -Match 'git pull'
        $update | Should -Match 'git checkout v'
        $update | Should -Match 'azd up'
        $update | Should -Match '(?m)^\| `VMF_HOSTING_PLAN` \|' -Because 'the table lists every recorded choice a person can change'
        $update | Should -Match '(?m)^\| `VMF_FIRST_SCOPE` \|' -Because 'the table lists every recorded choice a person can change'
    }
}

# PUBLIC-SYNC-1: the work items do not ship to the public repository.
Describe 'PIPELINE-LATER-1: DIST-2 and CD-2 stage B wait until after 1.0' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'docs' 'backlog'))) {

    BeforeAll {
        $script:boardRows = foreach ($f in @(Get-ChildItem (Join-Path $script:repoRoot 'docs' 'backlog') -Filter '*.md') + @(Get-Item (Join-Path $script:repoRoot 'docs' 'backlog.md'))) {
            foreach ($m in [regex]::Matches((Get-Content $f.FullName -Raw), '(?m)^>\s*\*\*Open board\*\*\s*\|(?<rest>.*)$')) {
                $parts = $m.Groups['rest'].Value -split '\|', 4
                [pscustomobject]@{ Section = $parts[0].Trim(); Label = $parts[2].Trim(); Text = $parts[3] }
            }
        }
    }

    It 'DIST-2 is on the After 1.0 board, naming the decision and where the page is kept' {
        $row = @($script:boardRows | Where-Object Label -eq '**DIST-2**')
        $row.Count | Should -Be 1
        $row[0].Section | Should -Be 'After 1.0'
        $row[0].Text | Should -Match 'PIPELINE-LATER-1'
        $row[0].Text | Should -Match 'docs/later/pipeline'
    }

    It 'CD-2 stage B is on the After 1.0 board, naming the decision' {
        $row = @($script:boardRows | Where-Object Label -eq '**CD-2 stage B**')
        $row.Count | Should -Be 1
        $row[0].Section | Should -Be 'After 1.0'
        $row[0].Text | Should -Match 'PIPELINE-LATER-1'
    }
}
