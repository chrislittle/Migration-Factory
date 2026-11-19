#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TEARDOWN-1 - what is removed before the platform, and what is removed after.
#
# MEASURED 2026-09-11 on a corporate subscription. An `azd up` failed
# on AKS capacity. `azd down` then:
#
#   * ran predown, which DELETED BOTH ENTRA REGISTRATIONS;
#   * deleted the deployment stack;
#   * DETACHED the 14 resources instead of deleting them;
#   * left 25 deny assignments owned by a stack that no longer existed, which
#     then refused every attempt to delete the resource group by hand;
#   * printed "No Azure resources were found" and "SUCCESS: Your application
#     was removed from Azure in 15 seconds".
#
# The platform was intact, billing, undeletable by hand, and unusable - because
# the ONE step that succeeded was the one that took sign-in away.
#
# The rule this file holds: a thing outside the stack is removed AFTER the
# stack, never before. `postdown` runs only when the removal succeeded, so a
# teardown that fails leaves a product that still works.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:predown  = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'predown.ps1')
    $script:postdown = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'postdown.ps1')
    $script:yaml     = Get-Content (Join-Path $script:repoRoot 'azure.yaml') -Raw
}

Describe 'TEARDOWN-1: nothing outside the stack is removed before the stack' {

    It 'the hook exists and azd is told to run it' {
        # Read zero and everything below passes on nothing.
        Test-Path (Join-Path $script:repoRoot 'infra' 'hooks' 'postdown.ps1') | Should -BeTrue
        $script:yaml | Should -Match '(?s)postdown:\s*\r?\n\s*shell: pwsh\s*\r?\n\s*run: \./infra/hooks/postdown\.ps1'
    }

    It 'predown DELETES NOTHING' {
        # It reports what the removal will leave behind. That is all it does,
        # and it is the only thing that is safe to do before the removal has
        # been attempted.
        $script:predown | Should -Not -Match 'az ad app delete'
        $script:predown | Should -Not -Match 'Remove-Az'
        $script:predown | Should -Not -Match 'az .* delete'
    }

    It 'and it does not even ASK, because an answer can go missing between hooks' {
        # DRILL-F, 2026-09-09: `azd down` clears recorded decisions. A question
        # answered in predown and read back in postdown is a question whose
        # answer may not survive the trip - so it is asked where the work is.
        $script:predown | Should -Not -Match 'VMF_REMOVE_REGISTRATIONS'
        $script:postdown | Should -Match "Read-VmfChoice -Name 'VMF_REMOVE_REGISTRATIONS'"
    }

    It 'postdown is where the registrations go' {
        $script:postdown | Should -Match 'az ad app delete'
        $script:postdown | Should -Match 'Get-VmfEntraApplication -DisplayName'
    }

    It 'and it resolves BOTH before it deletes EITHER' {
        # A display name is not unique in Entra, and a lookup that fails
        # halfway through must not leave one registration deleted and the other
        # found by a name that matched two applications.
        $script:postdown | Should -Match '\$found = foreach \(\$want in @\(@\(\$names\.Api, ''VMF_API_APP_ID''\), @\(\$names\.Dashboard, ''VMF_DASHBOARD_APP_ID''\)\)\)'
        $script:postdown.IndexOf('$found = foreach') |
            Should -BeLessThan $script:postdown.IndexOf('az ad app delete')
    }

    It 'the registration state is cleared where the registrations are' {
        # VMF_REGISTRATION_KEY exists so the NEXT install cannot collide with
        # the tombstones this removal creates. Clearing it in predown would
        # arm the next install for a removal that then did not happen.
        $script:postdown | Should -Match "Set-AzdValue -Name 'VMF_REGISTRATION_KEY' -Value ''"
        $script:postdown | Should -Match "Set-AzdValue -Name 'VMF_REMOVE_REGISTRATIONS' -Value ''"
        $script:predown | Should -Not -Match 'VMF_REGISTRATION_KEY'
    }

    It 'and it is cleared on BOTH answers, not only when they were removed' {
        # The question has been answered either way. Leaving the choice behind
        # would mean the next install never asks it.
        $kept = [regex]::Match($script:postdown, "(?s)if \(\`$remove -ne 'yes'\) \{.*?\}").Value
        $kept | Should -Not -BeNullOrEmpty
        $kept | Should -Match 'Clear-VmfRegistrationState'
    }
}

Describe 'TEARDOWN-1: the manual says what a failed removal leaves' {

    It 'and the way out is now one command, because there is nothing to unpick' {
        # This checked a FIVE-STEP recovery: a deny assignment can only be
        # removed by the stack that made it, so an orphaned set needed the
        # stack recreated under the same name with an empty template.
        #
        # NO-STACKS-1 removed the thing that made them. A resource group left
        # behind by a failed removal is now just a resource group, and the page
        # says so in one command.
        $fails = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'if-it-fails.md') -Raw
        $fails | Should -Not -Match '(?i)deny assignment'
        $fails | Should -Not -Match 'az stack sub'
        $fails | Should -Match 'az group delete --name'
        # and the removal page sends a reader there rather than repeating it
        $remove = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'remove.md') -Raw
        $remove | Should -Match 'if-it-fails\.md'
    }

    It 'and says that a removal can report success having removed nothing' {
        # The message was "No Azure resources were found" and "SUCCESS: Your
        # application was removed from Azure in 15 seconds", with every
        # resource still running. Somebody who believes it walks away from a
        # platform that bills.
        $remove = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'remove.md') -Raw
        $remove | Should -Match '(?i)check that the resource group is gone'
        $remove | Should -Match 'ResourceGroupNotFound' -Because 'the reader needs the answer that means success'
        $fails = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'if-it-fails.md') -Raw
        $fails | Should -Match '(?i)the removal said it worked and everything is still there'
    }
}
