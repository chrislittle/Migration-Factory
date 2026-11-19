#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DRILL-F, 2026-09-09: the first time the uninstall's safety-copy guard was
# fired at a real lock, IT LET THE REMOVAL THROUGH - and printed a count it
# had never made.
#
# The drill was meant to be a formality. It placed a lock named
# vmf-safety-copy on the proof resource group, ran the hook, and expected a
# refusal. The hook said "locked safety copies in the subscription: 0" and
# carried on. The lock was there; `az lock list` returned it; the same three
# lines of code, run in the shell beside it, counted 1.
#
# The difference was that the hook read the subscription id from the azd
# environment and got nothing, so `if ($subscription)` skipped the whole
# count. The guard did not fail. IT NEVER RAN, and reported a clean result.
#
# The same run showed the second defect: the registration names came out as
# 'vmf-api-' and 'vmf-dashboard-', built from an empty environment name. The
# hook looked for them, said "was not found" for both, removed nothing, and
# exited 0.
#
# Both are the same mistake: a missing input read as a benign value. These
# tests hold the two guards in place.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:hooks    = Join-Path $script:repoRoot 'infra' 'hooks' 'AzdHooks.ps1'
    $script:predown  = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'predown.ps1') -Raw

    # Run in a child pwsh: AzdHooks.ps1 sets strict mode and reads process
    # environment variables, and a test must not do either to its siblings.
    function Invoke-Names {
        param([string]$EnvName = '', [string]$Api = '', [string]$Dashboard = '')
        $script = @"
`$env:AZURE_ENV_NAME = '$EnvName'
`$env:VMF_API_DISPLAY_NAME = '$Api'
`$env:VMF_DASHBOARD_DISPLAY_NAME = '$Dashboard'
. '$script:hooks'
try { `$n = Get-VmfRegistrationNames; "OK|`$(`$n.Api)|`$(`$n.Dashboard)" }
catch { "THREW|`$(`$_.Exception.Message)" }
"@
        $out = & pwsh -NoProfile -NonInteractive -Command $script 2>&1
        $global:LASTEXITCODE = 0
        ($out | Where-Object { $_ -match '^(OK|THREW)\|' } | Select-Object -First 1).ToString()
    }
}

Describe 'DRILL-F: a registration name is never built from nothing' {

    It 'refuses when there is no environment name and no recorded name' {
        # It returned 'vmf-api-'. Nothing has ever been called that, so the
        # search that follows can only say "was not found" - which reads as
        # "there is nothing to remove", the opposite of what happened.
        $result = Invoke-Names
        $result | Should -Match '^THREW\|'
        $result | Should -Match 'AZURE_ENV_NAME is not set'
    }

    It 'and says WHY: azd is not running this hook' {
        # The value comes from azd. If it is empty, the hook was started by
        # hand, and that is the one thing worth telling the reader.
        (Invoke-Names) | Should -Match 'azd is not running this hook'
    }

    It 'builds both names from the environment name' {
        Invoke-Names -EnvName 'vmf-proof' | Should -Be 'OK|vmf-api-vmf-proof|vmf-dashboard-vmf-proof'
    }

    It 'and a recorded name always wins, even with no environment name' {
        # An install that adopted existing registrations records their real
        # names. Those names do not have to match the environment name.
        Invoke-Names -Api 'vmf-api-old' -Dashboard 'vmf-dashboard-old' |
            Should -Be 'OK|vmf-api-old|vmf-dashboard-old'
    }
}

Describe 'DRILL-F: a guard never states a count it did not make' {
    # The drill: this printed "locked safety copies in the subscription: 0"
    # having called az not at all, and let the removal go ahead. Reporting a
    # measurement that was never taken is the defect, and it is the same one as
    # a readiness check reporting an ok it never measured.
    #
    # FIND-COPY-1 changed what the hook DOES about the answer - it tells you
    # and lets you through, rather than refusing with a variable to walk past
    # the refusal - but not what it may SAY. A number here is still only a
    # number that was measured.

    It 'a missing subscription id is named as a reason, not counted as zero' {
        $script:predown | Should -Match "cannotCount = 'AZURE_SUBSCRIPTION_ID is not set'"
    }

    It 'a directory call that fails is also a reason' {
        # It cleared the exit code and carried on with $all still null, which
        # counts as zero. Throttling and a missing role both land here.
        $script:predown | Should -Match 'could not be listed'
    }

    It 'and it never prints a number it did not measure' {
        $script:predown | Should -Match 'not counted, because \$cannotCount'
    }

    It 'the tag search is RUN, not printed as a command and hoped for' {
        # POLICY-REVERT-1: a modify policy strips tags and reports success. A
        # command printed without being run would answer "none" for a
        # subscription full of copies, which is the same defect as the count
        # that was never made - an answer nobody measured.
        $script:predown | Should -Match 'az resource list --tag vmfSafetyCopy=true --subscription'
        $script:predown | Should -Match '\$tagged = \$null'
        # and a failed search is not zero copies
        # INSTALL-THROTTLE-RETRY-2: a listing that fails leaves $tagged unset.
        $script:predown | Should -Match 'if \(\$copyRead\.ExitCode -eq 0\) \{ \$tagged = '
    }

    It 'and copies that carry no tags are still pointed at, by their lock' {
        # The case the tag search cannot answer: a policy removed the tags, or
        # the copies were taken before this product wrote any. Saying "none
        # found" there would stranded somebody worse than saying nothing.
        $script:predown | Should -Match '(?s)elseif \(\$null -ne \$locks -and \$locks\.Count -gt 0\)'
        $script:predown | Should -Match 'listed by their lock instead'
    }
}

Describe 'FIND-COPY-1: the removal tells you, and does not stop you' {

    It 'nothing in the hook refuses over safety copies' {
        # Since 2026-09-10, the hook says the copies are left behind, and gives
        # the az command, based on tags, for the customer to clean them up.
        #
        # The gate only ever fired on `azd down` - the portal, `az group
        # delete` and a lapsed subscription all skip this hook - and it carried
        # its own way out. What it cost was a clear message.
        # To the END of the file: TEARDOWN-1 moved the registration section
        # out, so the safety-copy section is the last thing predown does and
        # there is no second Write-Step to stop at.
        $copies = [regex]::Match($script:predown, "(?s)Write-Step 'Safety copies'.*").Value
        $copies | Should -Not -BeNullOrEmpty -Because 'the safety-copies section must still exist'
        $copies | Should -Not -Match 'throw' -Because 'a warning that stops the removal is a gate, not a warning'
    }

    It 'and the variable that walked past the gate is gone everywhere' {
        # It existed only to escape a refusal that no longer exists. Left
        # behind it would read as a setting that still does something.
        $script:predown | Should -Not -Match 'azd env set VMF_ACCEPT_PENDING_COPIES'
        $script:predown | Should -Not -Match '\$accept'
        $manual = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'remove.md') -Raw
        $manual | Should -Not -Match 'VMF_ACCEPT_PENDING_COPIES'
        $manual | Should -Not -Match '(?i)accept the loss'
    }

    It 'it says the two things a person cannot work out for themselves' {
        # Where the copies are, and that the thing which would have deleted
        # them is what they are removing. Everything else is on the screen.
        $script:predown | Should -Match '(?i)resource groups of the machines they came from'
        $script:predown | Should -Match '(?i)removes the daily pass'
    }

    It 'and it hands over a command that still works once the product is gone' {
        # The whole point. Every other way of finding these - the run store,
        # the dashboard card, the retention record - goes with the product.
        $script:predown | Should -Match 'az resource list --tag vmfSafetyCopy=true -o table'
        # no --query with a filter: PowerShell's az shim eats [ and ?, and this
        # line is one a customer copies into a prompt.
        $script:predown | Should -Not -Match '--query "\['
    }
}
