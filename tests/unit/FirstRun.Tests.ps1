#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# FIRSTRUN-1: the install asks, and then gives the installer what they need.
#
# The install granted the product no reach over any machine, and the only route
# to that was the Admin page - which needs permissions over the DIRECTORY that
# one person with one subscription may not hold. That wall is
# a horrible experience for somebody migrating a few
# machines in a subscription they own.
#
# THE ADMINISTRATOR ROLE WAS NEVER THE MISSING HALF. The facade deploy has
# given the person installing the Vmf.Admin role since CD-1. What it never did
# was CHECK, so the closing line said "You are the administrator" on installs
# where the directory had refused.
#
# What is tested here is the WIRING and the reporting. The grant itself has
# been built and tested since ONBOARD-1, and the defect was never in it.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:prePath  = Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1'
    $script:postPath = Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1'
    $script:pre      = Get-VmfCodeOnly -Path $script:prePath
    $script:post     = Get-VmfCodeOnly -Path $script:postPath
    $script:grant    = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1')

    # The grant call, found in the SYNTAX TREE rather than in the text, so the
    # question "is it inside a try" has a real answer.
    $errs = $null
    $script:postAst = [System.Management.Automation.Language.Parser]::ParseFile($script:postPath, [ref]$null, [ref]$errs)
    $script:postErrors = @($errs)
    # THE CALL, not a mention of it. Two Write-Host lines name the script as
    # something to run by hand, and one of them is deliberately outside the
    # try - so matching any command whose text says Grant-VmfAccess tested the
    # wrong thing and failed. An invocation operator is what separates them.
    $script:grantCalls = @($script:postAst.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.CommandAst] -and
        $n.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
        "$n" -match 'Grant-VmfAccess'
    }, $true))
}

Describe 'FIRSTRUN-1: the install asks before it grants' {

    It 'both hooks parse' {
        $script:postErrors.Count | Should -Be 0
        $e = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:prePath, [ref]$null, [ref]$e) | Out-Null
        @($e).Count | Should -Be 0
    }

    It 'asks the question, and the answer is recorded' {
        $script:pre | Should -Match "VMF_FIRST_SCOPE"
        $script:pre | Should -Match 'Read-VmfChoice'
    }

    It 'never grants more than the person chose, whatever the default is' {
        # The default follows the person now, so it is not a fixed string. What
        # must hold in every case: nothing is granted without an answer, and the
        # answer that grants nothing is always offered.
        $script:pre | Should -Match '-Default \$default'
        # RULED 2026-09-22: an Owner of a subscription can migrate, so scan
        # and migrate is the default answer.
        $script:pre | Should -Match "\`$default = 'migrate'"
        $values = @([regex]::Matches($script:pre, "'(?<v>no|assess|migrate)\|") | ForEach-Object { $_.Groups['v'].Value })
        $values | Should -Contain 'no'
        $values | Should -Contain 'assess'
        $values | Should -Contain 'migrate'
    }

    It 'and does NOT stop an install that has no console' {
        # The default here is one a person in the same position could have
        # chosen, so an unattended install takes it and carries on.
        # PIPELINE-LATER-1 removed -Consequential, the switch that stopped an
        # install instead; its one caller was the update question. So the
        # rule now is that Read-VmfChoice takes the default with no console.
        $ask = [regex]::Match($script:pre, '(?s)Read-VmfChoice -Name ''VMF_FIRST_SCOPE''.*?-Options \$options').Value
        $ask | Should -Not -BeNullOrEmpty
        $hooks = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'AzdHooks.ps1') -Raw
        $hooks | Should -Match 'no console; the default is taken'
    }
}

Describe 'FIRSTRUN-1: the install reads what the person holds' {
    # Since 2026-09-15 the install reads the user's role and gives guidance
    # from it. Two different rights decide this, and calling both of them
    # "administrator" is what made the wall so hard to see.

    BeforeAll {
        $script:rightsPath = Join-Path $script:repoRoot 'infra' 'Resolve-VmfInstallerRights.ps1'
        $script:rights = Get-VmfCodeOnly -Path $script:rightsPath
        . $script:rightsPath
    }

    It 'parses, and the hook reads it rather than repeating it' {
        $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:rightsPath, [ref]$null, [ref]$errs) | Out-Null
        @($errs).Count | Should -Be 0
        $script:pre | Should -Match 'Resolve-VmfInstallerRights\.ps1'
        $script:pre | Should -Match 'Get-VmfInstallerRights -SubscriptionId'
    }

    It 'judges on the role NAME, never on the scope it was assigned at' {
        # MEASURED 2026-09-15: a test user holds Owner of a tenant through
        # two management groups and holds NO assignment on the subscription
        # itself. A check that matched the scope string would have told the
        # Owner of everything that the user may grant nothing.
        $script:rights | Should -Match '--include-inherited'
        $script:rights | Should -Match 'roleDefinitionName'
        $script:rights | Should -Not -Match '\$_\.scope -eq'
    }

    It 'asks Microsoft Entra ID which directory roles are active' {
        $script:rights | Should -Match 'me/memberOf'
        $script:rights | Should -Match 'microsoft\.graph\.directoryRole'
    }

    It 'and keeps ONE list of the roles that can consent' {
        # tools/Test-VmfConsentReadiness.ps1 answers the same question. Two
        # lists would drift, and the answer would depend on which one a person
        # happened to run.
        $script:rights | Should -Match 'Privileged Role Administrator'
        $script:rights | Should -Match 'Cloud Application Administrator'
        # CONSENT-TOOL-LINK-1: the tool reads this file's list and holds none.
        $tool = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Test-VmfConsentReadiness.ps1')
        $tool | Should -Match 'Resolve-VmfInstallerRights\.ps1'
        $tool | Should -Match 'VmfConsentAnyPermission'
        $tool | Should -Match 'VmfConsentDelegatedOnly'
        foreach ($role in @('Global Administrator', 'Privileged Role Administrator',
                            'Cloud Application Administrator', 'Application Administrator', 'AI Administrator')) {
            $script:rights | Should -Match ([regex]::Escape($role))
        }
    }

    It 'a refused read is UNKNOWN, and UNKNOWN is never read as no' {
        # Measured twice, once for an account holding Global Administrator: a
        # directory read comes back unauthorized. A check that turned that into
        # "no" would take away the only answer that works.
        $script:rights | Should -Match "CanGrant     = 'unknown'"
        $script:rights | Should -Match "CanConsent   = 'unknown'"
        $script:pre | Should -Match "\`$rights\.CanConsent -ne 'no'"
    }
}

Describe 'FIRSTRUN-1: the rights reader, run rather than read' {
    # Two mutations survived a source-matching version of this file: hard-wiring
    # the answer to 'no', and asking a Contributor a question anyway. Both are
    # invisible to a check that reads the script, and both change what a person
    # is told - so the function is CALLED here, with Azure stubbed out.

    BeforeAll {
        . (Join-Path $script:repoRoot 'infra' 'Resolve-VmfInstallerRights.ps1')
        function global:az {
            $joined = $args -join ' '
            foreach ($key in $script:answers.Keys) {
                if ($joined -like $key) { return $script:answers[$key] }
            }
            $null
        }
    }
    AfterAll { Remove-Item function:az -ErrorAction SilentlyContinue }

    BeforeEach {
        $script:answers = @{
            '*account show*'        = 'user'
            '*signed-in-user show*' = '11111111-1111-1111-1111-111111111111'
        }
    }

    It 'reads Owner inherited from a management group as yes' {
        # THE MEASURED CASE, 2026-09-15: a test user holds Owner of a tenant
        # through two management groups and nothing on the subscription itself.
        $script:answers['*role assignment list*'] = '[{"roleDefinitionName":"Owner","scope":"/providers/Microsoft.Management/managementGroups/prod"},{"roleDefinitionName":"User Access Administrator","scope":"/"}]'
        $r = Get-VmfInstallerRights -SubscriptionId '11111111-2222-3333-4444-555555555555'
        $r.CanGrant | Should -Be 'yes'
        $r.GrantRoles | Should -Contain 'Owner'
    }

    It 'reads a Contributor as no' {
        $script:answers['*role assignment list*'] = '[{"roleDefinitionName":"Contributor"}]'
        (Get-VmfInstallerRights -SubscriptionId 'x').CanGrant | Should -Be 'no'
    }

    It 'reads a refused subscription read as UNKNOWN, not as no' {
        # The difference decides whether somebody is offered the only answer
        # that would work for them.
        (Get-VmfInstallerRights -SubscriptionId 'x').CanGrant | Should -Be 'unknown'
    }

    It 'reads a refused directory read as UNKNOWN, not as no' {
        # Measured twice, once for an account holding Global Administrator.
        $script:answers['*role assignment list*'] = '[{"roleDefinitionName":"Owner"}]'
        (Get-VmfInstallerRights -SubscriptionId 'x').CanConsent | Should -Be 'unknown'
    }

    It 'reads a directory role that can consent' {
        $script:answers['*memberOf*'] = '{"value":[{"@odata.type":"#microsoft.graph.directoryRole","displayName":"Global Administrator"},{"@odata.type":"#microsoft.graph.group","displayName":"Some group"}]}'
        $r = Get-VmfInstallerRights -SubscriptionId 'x'
        $r.CanConsent | Should -Be 'yes'
        $r.ConsentRoles | Should -Be @('Global Administrator')
    }

    It 'and a directory role that cannot' {
        # Azure DevOps Administrator is a directory role and approves nothing
        # here. The measured test user holds it beside Global Administrator.
        $script:answers['*memberOf*'] = '{"value":[{"@odata.type":"#microsoft.graph.directoryRole","displayName":"Azure DevOps Administrator"}]}'
        (Get-VmfInstallerRights -SubscriptionId 'x').CanConsent | Should -Be 'no'
    }

    It 'asks the directory nothing when a service principal runs the install' {
        # The answers below are ready for it. If it reads them, it has gone
        # looking for rights on behalf of something that is not a person - and
        # CD-1 keeps directory reads out of the pipeline path on purpose.
        $script:answers['*account show*'] = 'servicePrincipal'
        $script:answers['*role assignment list*'] = '[{"roleDefinitionName":"Owner"}]'
        $script:answers['*memberOf*'] = '{"value":[{"@odata.type":"#microsoft.graph.directoryRole","displayName":"Global Administrator"}]}'
        $r = Get-VmfInstallerRights -SubscriptionId 'x'
        $r.IsPerson | Should -BeFalse
        $r.CanGrant | Should -Be 'unknown'
        $r.CanConsent | Should -Be 'unknown'
    }
}

Describe 'FIRSTRUN-1: what it reads decides what it asks' {

    It 'asks nothing of somebody who could not act on any answer' {
        # A Contributor cannot give the product permission over machines. Every
        # answer would fail, and a question whose answers all fail is worse
        # than no question.
        #
        # ASKED OF THE SYNTAX TREE. A text version of this test passed while
        # the guard was mutated to `if ($false)`, because the same words appear
        # a few lines above, in the sentence that explains the situation.
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:prePath, [ref]$null, [ref]$errs)
        @($errs).Count | Should -Be 0
        $asks = @($ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.CommandAst] -and "$n" -match 'Read-VmfChoice.*VMF_FIRST_SCOPE'
        }, $true))
        $asks.Count | Should -Be 1
        $node = $asks[0].Parent
        $guard = $null
        while ($node) {
            if ($node -is [System.Management.Automation.Language.IfStatementAst]) { $guard = $node; break }
            $node = $node.Parent
        }
        $guard | Should -Not -BeNullOrEmpty -Because 'the question must sit behind what the person can do'
        "$($guard.Clauses[0].Item1)" | Should -Match 'CanGrant'
        $script:pre | Should -Match "Set-AzdValue -Name 'VMF_FIRST_SCOPE' -Value 'no'"
        $script:pre | Should -Match 'Ask an Owner of this subscription'
    }

    It 'sends a person to the Admin page only when it will work for them' {
        # It covers a resource group, a subscription or a management group, and
        # takes permission away again - so it is the better answer for anybody
        # who can use it, and a wall for anybody who cannot.
        $script:pre | Should -Match '\$sendToAdminPage = \(\$rights\.CanConsent -ne ''no''\)'
        # FIRSTSCOPE-1: consent decides WHERE a person is pointed, never WHAT
        # they get. Giving admin consent is a DIRECTORY question about the app
        # registration; granting the product reach over MACHINES is an AZURE
        # question about their role on the subscription, and the guard above
        # has already answered it. Reading the wrong one is what left the
        # corporate install able to scan and unable to migrate.
        $defaultLine = [regex]::Match($script:pre, '(?m)^\s*\$default = .*$').Value
        $defaultLine | Should -Not -BeNullOrEmpty
        $defaultLine | Should -Not -Match 'sendToAdminPage'
        $defaultLine | Should -Not -Match 'CanConsent'
        $defaultLine | Should -Match "'migrate'"
    }

    It 'and says which administrator is missing, in Azure words' {
        $script:pre | Should -Match 'Owner or User Access Administrator'
        $script:pre | Should -Match 'admin consent in Microsoft Entra ID'
    }

    It 'names what the Admin page can do that this question cannot' {
        $script:pre | Should -Match 'a resource group, a subscription or a management group'
    }
}
Describe 'FIRSTRUN-1: what the install does with the answer' {

    It 'calls the grant that already exists, rather than a second one' {
        $script:grantCalls.Count | Should -BeGreaterThan 0
    }

    It 'and the call is inside a try, so a refused grant cannot fail the install' {
        # The largest risk in this change: an install that succeeds today must
        # not start failing because a directory said no. The platform is
        # deployed by this point and the app has a page for the grant.
        foreach ($call in $script:grantCalls) {
            $node = $call.Parent
            $inTry = $false
            while ($node) {
                if ($node -is [System.Management.Automation.Language.TryStatementAst]) { $inTry = $true; break }
                $node = $node.Parent
            }
            $inTry | Should -BeTrue -Because 'a grant that is refused must be reported, not thrown'
        }
    }

    It 'grants only the subscription being installed into' {
        $script:post | Should -Match 'AZURE_SUBSCRIPTION_ID'
        $script:post | Should -Match '/subscriptions/\$subId'
    }

    It 'passes ONE scope for migrate, because the migration role contains the assessment role' {
        # infra/roles.bicep unions the two action lists. Passing both would
        # make a second, pointless assignment and imply they are different
        # places.
        $script:post | Should -Match "if \(\`$firstScope -eq 'assess'\) \{ \`$grantArgs\.AssessScope"
        $script:post | Should -Match "else \{ \`$grantArgs\.MigrateScope"
        # ONE each, so neither branch can quietly pass both.
        @([regex]::Matches($script:post, 'AssessScope')).Count | Should -Be 1
        @([regex]::Matches($script:post, 'MigrateScope')).Count | Should -Be 1
    }

    It 'grants nothing at all when the answer is no' {
        # The default answer, and what every install does today. The call has
        # to sit behind the answer, not beside it.
        # Asked of the syntax tree: is the call inside an if, and does that if
        # test the answer? A regex over the text cannot see a nested brace.
        foreach ($call in $script:grantCalls) {
            $node = $call.Parent
            $guard = $null
            while ($node) {
                if ($node -is [System.Management.Automation.Language.IfStatementAst]) { $guard = $node; break }
                $node = $node.Parent
            }
            $guard | Should -Not -BeNullOrEmpty -Because 'the grant must sit behind the answer, not beside it'
            "$($guard.Clauses[0].Item1)" | Should -Match 'firstScope'
        }
    }

    It 'does not assign the administrator role a second time' {
        # tools/Deploy-VmfFacade.ps1 does that in step 3, minutes earlier. A
        # second assignment here would be a duplicate object in the directory
        # for somebody to read, judge and remove.
        $script:post | Should -Not -Match 'FirstAdmin'
    }
}

Describe 'FIRSTRUN-1: the install stops claiming what did not happen' {

    It 'only calls you the administrator if somebody was made one' {
        $lines = @(($script:post -split "`n") | Where-Object { $_ -match 'You are the administrator' })
        $lines.Count | Should -BeGreaterThan 0
        foreach ($line in $lines) {
            $line | Should -Match 'adminDone' -Because 'the line used to print on every install, including the ones where nobody was granted anything'
        }
    }

    It 'and says so plainly when the person installing does not hold it' {
        $script:post | Should -Match 'YOU DO NOT HOLD THE ADMINISTRATOR ROLE'
    }

    It 'the scope sentence follows what was granted, not what was hoped' {
        $lines = @(($script:post -split "`n") | Where-Object { $_ -match 'no reach over your machines' })
        $lines.Count | Should -BeGreaterThan 0
        $script:post | Should -Match '\$scopeDone'
    }
}

Describe 'FIRSTRUN-1: the install measures whether you can sign in' {

    It 'reads the role assignment back rather than trusting the call that made it' {
        $script:post | Should -Match 'appRoleAssignments'
        $script:post | Should -Match '\$adminDone = \[bool\]'
    }

    It 'and the facade deploy stops claiming a grant it never checked' {
        $facade = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Deploy-VmfFacade.ps1')
        $facade | Should -Not -Match 'granted: Vmf\.Admin'
        $facade | Should -Match 'asked the directory for Vmf\.Admin'
    }

    It 'says nothing about administrators when a service principal installed' {
        $script:post | Should -Match '\$installerIsPerson'
        $lines = @(($script:post -split "`n") | Where-Object { $_ -match 'DO NOT HOLD THE ADMINISTRATOR' })
        $lines.Count | Should -BeGreaterThan 0
    }
}

Describe 'FIRSTRUN-1: the grant reports what it measured' {

    It 'reads the role assignment back instead of trusting the call' {
        # It printed "granted: Vmf.Admin" whatever happened: the exit code was
        # discarded, because an already-assigned role answers with an error and
        # that is success here. The install now repeats that line to the
        # person, so it has to be true.
        $said = @([regex]::Matches($script:grant, "(?s)if \(\`$FirstAdmin\) \{.*?\n\}") |
            Where-Object { $_.Value -match '--method POST' } | ForEach-Object { $_.Value })[0]
        $said | Should -Not -BeNullOrEmpty
        $said | Should -Match 'appRoleAssignments'
        $said | Should -Match "--method GET"
        # The read-back has to DECIDE the sentence, not merely happen beside
        # it. A mutation that kept the read and printed anyway went unnoticed
        # until this line, which is the same shape as the defect itself.
        $printed = @(($said -split "`n") | Where-Object { $_ -match 'granted: Vmf\.Admin' })
        $printed.Count | Should -BeGreaterThan 0
        foreach ($line in $printed) { $line | Should -Match '\$held' }
    }

    It 'and refuses rather than reporting a grant that is not there' {
        $said = @([regex]::Matches($script:grant, "(?s)if \(\`$FirstAdmin\) \{.*?\n\}") |
            Where-Object { $_.Value -match '--method POST' } | ForEach-Object { $_.Value })[0]
        $said | Should -Not -BeNullOrEmpty
        $said | Should -Match 'throw'
    }

    It 'with no bracket query and no second query parameter' {
        # CLAUDE.md, both measured here: cmd eats the bracket in --query "[?...]"
        # and treats & as a command separator, and what comes back looks like
        # an answer.
        foreach ($line in ($script:post -split "`n")) {
            if ($line -notmatch 'graph\.microsoft\.com|management\.azure\.com') { continue }
            $line | Should -Not -Match '&'
        }
        $script:post | Should -Not -Match '--query\s+"\[\?'
    }
}

Describe 'FIRSTSCOPE-2: the install says what it is about to grant, every time' {

    # The answer is recorded once and reused silently on every later install.
    # A corporate install was found unable to migrate, weeks after the answer
    # that decided it: the product could not migrate out of the box.
    #
    # The install DID print a line. It read "the product may scan this
    # subscription" - quiet, among a page of install output, saying nothing
    # about what scan-only forbids and nothing about the answer being weeks
    # old. Three things reported that install as fine and this was one of them.

    It 'notices when the answer is being reused rather than asked' {
        $script:pre | Should -Match '\$storedScope = Get-AzdValue -Name ''VMF_FIRST_SCOPE'''
    }

    It 'says so, so nobody takes a weeks-old answer for a fresh one' {
        $script:pre | Should -Match '(?i)answer you gave .*earlier install'
    }

    It 'and says what scan-only cannot do, in the words that matter' {
        # "may scan this subscription" is true and tells nobody they cannot
        # migrate. That is the sentence this item exists for.
        $script:pre | Should -Match '(?i)may NOT migrate'
    }

    It 'names how to change it, because the Admin page may refuse them' {
        # Somebody who cannot give admin consent has no route in the app, and
        # this is the installer's own console, not the operator app.
        $script:pre | Should -Match 'azd env set VMF_FIRST_SCOPE migrate'
    }

    It 'and still says the good case plainly' {
        $script:pre | Should -Match '(?i)may scan and migrate'
    }
}

Describe 'FIRSTSCOPE-3: the CLOSING line says which, because that is the line people read' {

    # The install ends with what it did. It said:
    #
    #     The product may work on the machines in subscription <id>,
    #     as you chose during the install.
    #
    # Scan-only and scan-and-migrate printed the SAME sentence. So the last
    # thing an installer reads could not tell them whether the product they
    # just installed can migrate a machine - and the line it contradicts sits
    # hundreds of lines earlier, in preprovision, scrolled off the screen.
    #
    # A reader who looked for this output could not find it in the install,
    # nor tell whether it was at the end.

    It 'no longer says the same thing whichever was chosen' {
        $script:post | Should -Not -Match 'The product may work on the machines in subscription'
    }

    It 'says SCAN AND MIGRATE when it may' {
        $script:post | Should -Match '(?i)may SCAN AND MIGRATE'
    }

    It 'and the two sentences really are on different branches' {
        # A mutation survived the first version of this: forcing the condition
        # true still leaves BOTH sentences in the file, so checking that each
        # one exists proves nothing about which is printed. Ask what the branch
        # is ON.
        $block = [regex]::Match($script:post, '(?s)if \(\$scopeDone\) \{.*?\n\}').Value
        $block | Should -Not -BeNullOrEmpty
        $block | Should -Match "\`$firstScope -eq 'migrate'"
        $block | Should -Match '(?i)may SCAN AND MIGRATE'
        $block | Should -Match '(?i)may NOT migrate a machine'
    }

    It 'and says it may NOT migrate when it may not' {
        $script:post | Should -Match '(?i)may NOT migrate a machine'
    }

    It 'with the way to change it, since the Admin page may refuse them' {
        $script:post | Should -Match 'azd env set VMF_FIRST_SCOPE migrate'
    }

    It 'and stops promising the Admin page to people it will refuse' {
        # "Widen or narrow that on the Admin page at any time" is untrue for
        # anybody whose directory reserves consent for an administrator, which
        # is exactly the person who most needs to know.
        $script:post | Should -Not -Match 'on the Admin page at any time'
    }
}
