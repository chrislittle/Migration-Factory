#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# NO-STACKS-1 - a resource group holds the platform, and nothing wraps it.
#
# The install used a deployment stack from 2026-09-05 and dropped it on
# 2026-09-11, after three teardown failures in two days. All three were on azd
# 1.34.0 and NONE of them was a fault of the Azure service:
#
#   * a removal that DETACHED all 14 resources and printed "SUCCESS: Your
#     application was removed from Azure in 15 seconds";
#   * 25 deny assignments that outlived their stack and then refused every
#     attempt to delete the resource group by hand - a deny assignment is not
#     user-deletable, so the only way out was to recreate the stack;
#   * a removal blocked by a Container Apps job the stack did not manage,
#     created by infra/deploy.ps1, which is a second deployment path this
#     product needs and will keep.
#
# The third decided it. azd behaved correctly there; the MODEL is the problem.
# A stack deletes resource by resource in an order computed from its own
# inventory, and anything in the group it does not manage can block that.
# Without one, `azd down` deletes the RESOURCE GROUP and Azure orders what is
# inside it, whoever made it.
#
# This file is the removal, tested. Is there any reason to keep stacks?
# After four measured failures, no.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:yaml    = Get-Content (Join-Path $script:repoRoot 'azure.yaml') -Raw
    $script:preCode = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1')
    $script:pre     = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1') -Raw

    # NO-STACKS-2: what the OPERATOR READS during an install, and nothing else.
    #
    # COMMENT-TRAP-1 is the whole difficulty here. Every one of these hooks
    # carries long comments about why the product stopped using deployment
    # stacks, so a check over the file text matches its own explanation and
    # can never fail. These pull the STRING LITERALS out of the Write-Step,
    # Write-Host and throw lines of comment-free code - the words on the
    # screen.
    $script:hooks = 'preprovision', 'postprovision', 'predown', 'postdown', 'Test-VmfReadiness'
    $script:operatorText = @{}
    foreach ($hook in $script:hooks) {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' "$hook.ps1")
        $said = foreach ($line in ($code -split "`n")) {
            if ($line -match '(?i)\b(Write-Step|Write-Host|throw|Add-Check)\b') {
                foreach ($m in [regex]::Matches($line, "'([^']*)'|`"([^`"]*)`"")) {
                    $m.Groups[1].Value + $m.Groups[2].Value
                }
            }
        }
        $script:operatorText[$hook] = @($said)
    }
}

Describe 'NO-STACKS-1: the install deploys a template, not a stack' {

    It 'azure.yaml declares no deployment stack' {
        $script:yaml | Should -Not -Match '(?m)^\s*deploymentStacks:'
        $script:yaml | Should -Not -Match 'actionOnUnmanage'
        $script:yaml | Should -Not -Match 'denySettings'
    }

    It 'and the template is still deployed, or this proves nothing' {
        # A removal test that only checks absences passes just as well when
        # somebody deletes the whole infra block.
        $script:yaml | Should -Match '(?m)^\s*provider: bicep'
        $script:yaml | Should -Match '(?m)^\s*module: main'
    }

    It 'THE FLAG IS NOT TURNED ON, which is the half that is not in azure.yaml' {
        # Removing the block is not enough. The block supplies a stack's
        # OPTIONS; this setting enables the code path, and azd falls back to
        # its own defaults when the block is absent:
        #
        #   if deploymentStackOptions.ActionOnUnmanage == nil {
        #       deploymentStackOptions.ActionOnUnmanage = defaultDeploymentStackOptions.ActionOnUnmanage
        #   }
        #
        # So a machine with the flag on would still get stacks, with settings
        # nobody chose, and nothing saying so. Found by running
        # `azd config get alpha.deployment.stacks` on an install machine.
        #
        # A COMMAND, not the string: the hook PRINTS the off command as advice,
        # and a printed instruction is code.
        $script:preCode | Should -Not -Match '(?m)^\s*azd config set alpha\.deployment\.stacks'
    }

    It 'and it is not turned OFF either, because the setting is not ours' {
        # `azd config set` writes to the person's azd configuration, not to
        # this project, so it reaches every other azd project they have.
        # Turning it off has the same reach as turning it on did. This product
        # reports what it found and leaves the machine alone - the rule it
        # follows everywhere else it meets something it does not own.
        $script:pre | Should -Match '(?i)Turn it off if nothing else needs it'
        $script:pre | Should -Match '(?i)belongs to your machine, not to'
    }

    It 'the hook still LOOKS, so a machine with it on is told' {
        # Silence would be the worst of the three: the install would behave one
        # way on a machine that has ever installed this product and another way
        # everywhere else, with nothing saying which.
        $script:preCode | Should -Match 'azd config get alpha\.deployment\.stacks'
    }
}

Describe 'NO-STACKS-1: what the stack used to give, and what replaced it' {

    It 'deny-delete is gone, and the manual withdraws the promise' {
        # It was promised to the customer in choices.md. A promise withdrawn in
        # code and left standing in the manual is worse than either.
        $choices = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'choices.md') -Raw
        $choices | Should -Not -Match '(?i)deployment stack holds the platform'
        $choices | Should -Not -Match '(?i)cannot be deleted by accident'
        $choices | Should -Match '(?i)does not lock those resources'
    }

    It 'and the security page says what changed rather than going quiet' {
        # Removing a security property silently is the way somebody later
        # believes the product still has it.
        $security = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'technical' 'security.md') -Raw
        $security | Should -Match '(?i)does not stop a person deleting its own resources'
        # MANUAL-REVIEW-1 (2026-11-12): no install exists before 1.0, so the
        # page states the property as it is now, with no history and no date.
        $security | Should -Match '## The product does not lock its own resources'
        $security | Should -Not -Match '2026-09-11'
    }

    It 'the safety copies KEEP their locks, which is the exception' {
        # SAFETY-3 is a different mechanism and a different argument: a copy is
        # the way back for a machine, the lock is on one resource, and the
        # product removes it itself when retention ends. Dropping stacks must
        # not be read as dropping that.
        $rbac = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw
        $rbac | Should -Match 'Microsoft\.Authorization/locks/write'
        $rbac | Should -Match 'Microsoft\.Authorization/locks/delete'
        $ops = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1')
        $ops | Should -Match 'New-AzResourceLock'
    }

    It 'and NO lock is placed on the platform itself' {
        # Considered and declined: a CanNotDelete lock on the run store would
        # refuse `azd down`'s own deletion of it unless predown lifted it
        # first - the same shape as the failure this change removes. The
        # decision: option B, no lock.
        $template = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
        $template | Should -Not -Match 'Microsoft\.Authorization/locks'
    }
}

Describe 'NO-STACKS-1: the manual loses what only stacks caused' {

    BeforeAll {
        $script:fails = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'if-it-fails.md') -Raw
    }

    It 'the first-install failure that named the stack is explained, because it can still happen' {
        # NO-STACKS-2, 2026-09-14: THIS ASSERTED THE OPPOSITE AND WAS WRONG,
        # in two files at once. The reasoning was "it cannot happen without the
        # object the read was against" - true of the object, false of the
        # cause. azd's machine-wide `alpha.deployment.stacks` setting still
        # makes stacks whatever azure.yaml says, which is exactly what
        # preprovision.ps1 checks for, and an install hit it:
        #
        #     ResourceNotFound: The resource 'azd-stack-contoso-demo' was not found.
        # ANCHORED TO THE HEADING: the phrase also appears in the fenced
        # example inside the section, so matching it anywhere passed with the
        # section deleted. Mutation testing found that.
        # MANUAL-REVIEW-1: preprovision.ps1 now stops on the setting before it
        # creates anything, so that error cannot reach a 1.0 install. The page
        # explains the stop, and the command that clears it.
        $script:fails | Should -Match '(?m)^##\s.*deployment-stack mode is on'
        $script:fails | Should -Match 'alpha\.deployment\.stacks off'
        $script:fails | Should -Not -Match '(?m)^##\s.*referenced resource was not found'
    }

    It 'and so is the five-step deny-assignment recovery' {
        $script:fails | Should -Not -Match '(?i)deny assignment'
        $script:fails | Should -Not -Match 'az stack sub'
    }

    It 'but the check that a removal really removed survives, because that rule is not about stacks' {
        # TEARDOWN-1: a removal that reports success is not a removal that
        # happened, and the answer is to look.
        $script:fails | Should -Match '(?i)the removal said it worked and everything is still there'
        $script:fails | Should -Match 'az group show'
    }
}

Describe 'NO-STACKS-2: the install does not tell an operator about a stack' {

    # NO-STACKS-1 removed deployment stacks, updated the manual, and left the
    # INSTALLER'S OWN WORDS alone. Six operator-visible strings still named a
    # stack three days later, and an install showed them: the installer still
    # named stacks, such as 'outside the stack', after their removal.
    #
    # One of them was not jargon but a false statement: predown said "azd now
    # removes the deployment stack", when what happens is the resource group
    # is deleted.

    It 'found the words an operator reads, or none of this proves anything' {
        # Without this, a broken scraper makes every check below vacuous.
        foreach ($hook in $script:hooks) {
            @($script:operatorText[$hook]).Count |
                Should -BeGreaterThan 3 -Because "$hook should print more than three strings"
        }
    }

    It 'no step heading or message names a stack, except where it names azd''s own setting' {
        # THE ONE ALLOWED USE: the machine-wide azd setting really is called
        # `alpha.deployment.stacks`, and the step that refuses because it is on
        # has to say so. That is Azure's own name for a real thing the reader
        # must go and change. Everywhere else, this product has no stack, so
        # the word can only send somebody looking for one.
        $offenders = foreach ($hook in $script:hooks) {
            foreach ($said in $script:operatorText[$hook]) {
                if ($said -notmatch '(?i)stack') { continue }
                if ($said -match 'alpha\.deployment\.stacks') { continue }
                if ($said -match '(?i)deployment-stack mode') { continue }
                if ($said -match '(?i)azd-stack-') { continue }
                "$hook says: $said"
            }
        }
        @($offenders) | Should -BeNullOrEmpty
    }

    It 'the removal says what it actually deletes' {
        # It is the resource group, and Azure orders what is inside it. That
        # difference IS why NO-STACKS-1 happened, so the sentence a person
        # reads while removing the product should not describe the old way.
        $said = $script:operatorText['predown'] -join ' | '
        $said | Should -Match '(?i)deletes the resource group'
    }

    It 'the install REFUSES when stack mode is on, rather than warning and failing later' {
        # A warning bought nothing: the install cannot succeed with the flag
        # on, and the failure arrives minutes later naming azd-stack-<env> and
        # nothing else. Measured 2026-09-14.
        $script:preCode | Should -Match "throw 'Deployment-stack mode is on"
    }

    It 'and the refusal tells the operator the command, without running it' {
        $said = $script:operatorText['preprovision'] -join ' | '
        $said | Should -Match 'azd config set alpha\.deployment\.stacks off'
        # Still only ADVICE. The setting reaches every other azd project the
        # person has, so it stays theirs to change.
        $script:preCode | Should -Not -Match '(?m)^\s*azd config set alpha\.deployment\.stacks'
    }

    It 'AZD-UP-QUIET-1: with stack mode off, the install says nothing about it' {
        # Since 2026-11-10, the install does not mention stack mode when it is
        # off: the heading and "off; this install is an ordinary
        # deployment" named a feature this product does not use, every install.
        $script:preCode | Should -Match "(?s)if \(\`$stacks -match [^\r\n]*\{\s*Write-Step 'Deployment-stack mode" -Because 'the heading shows only when the setting is on'
        @($script:operatorText['preprovision'] | Where-Object { $_ -match '(?i)ordinary deployment' }) | Should -BeNullOrEmpty
        $script:preCode | Should -Not -Match "(?m)^Write-Step 'Deployment-stack mode"
    }
}
