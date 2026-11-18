#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CONSENT-SPLIT-1 - the Admin page does two jobs, and only one needs a
# directory administrator.
#
# Measured on a corporate subscription: the page showed `access_denied` and
# nothing else. Every card was gone, including the one that grants this product
# access to a SUBSCRIPTION - which needs no directory permission at all, only
# ownership of the subscription, which the person had.
#
#   Giving people roles     reads and writes Microsoft Entra   administrator only
#   Pointing it at Azure    an ordinary role assignment        subscription owner
#
# The page asked for the directory permission to SIGN IN, and read the
# directory as its first act. So the half a person was entitled to use was
# locked behind the half they were not, and the product could not be pointed at
# a single machine.
#
# These hold the separation. They are structural on purpose: the behaviour was
# driven in a browser, and what a test can keep is the ORDER - the Azure half
# reaches the screen before the directory half is allowed to fail.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:dash = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:raw = (Get-VmfPageSource -Path (Join-Path $script:dash 'access.html'))
    # COMMENT-TRAP-1: this page now EXPLAINS the change at length, naming the
    # very calls it stopped making. Only code is read.
    $script:code = Get-VmfCodeOnly -Path (Join-Path $script:dash 'access.html') -Language CStyle
}

Describe 'CONSENT-SPLIT-1: signing in does not ask for the directory' {

    It 'read the page as code, or nothing below proves anything' {
        $script:code.Length | Should -BeGreaterThan 20000
        # The page says GRAPH_SCOPES in a comment explaining the change. If the
        # first line fails the specimen is gone; if the second fails, comments
        # are reaching these checks.
        $script:raw | Should -Match 'used to ask for the directory permissions'
        $script:code | Should -Not -Match 'used to ask for the directory permissions'
    }

    It 'the sign-in button asks for this product, not for Entra' {
        # THE BUG: `signInRedirect(msalApp, GRAPH_SCOPES)` meant a directory
        # that refuses those permissions refused the whole page.
        $signIn = [regex]::Match($script:code, 'signInRedirect\([^)]*\)').Value
        $signIn | Should -Not -BeNullOrEmpty
        $signIn | Should -Not -Match 'GRAPH_SCOPES'
        $signIn | Should -Match 'access_as_user'
    }

    It 'the directory is still asked for somewhere, or the page cannot do its other job' {
        # Without this, deleting every Graph call passes the test above.
        $script:code | Should -Match 'GRAPH_SCOPES'
        $script:code | Should -Match 'getToken\(GRAPH_SCOPES'
    }

    It 'every call that CHANGES a role asks interactively, and only those' {
        # The other half of the silent default: a mutation follows a click, so
        # it may ask. A read never does.
        #
        # THE METHOD DOES NOT SAY WHICH IS WHICH, and assuming it did was wrong
        # the first time this was written: Graph looks up a batch of objects
        # with POST `directoryObjects/getByIds`, which changes nothing. What
        # marks a real change here is the ROLE ASSIGNMENT it writes or deletes.
        $calls = @([regex]::Matches($script:code, "(?s)graph\('(?:POST|DELETE)',.*?\);")) |
            ForEach-Object { $_.Value } |
            Where-Object { $_ -match 'appRoleAssignedTo' }
        @($calls).Count | Should -Be 4 -Because 'two grants and two removals'
        foreach ($call in $calls) {
            $call | Should -Match ', true\);\s*$' -Because "a change follows a click and may ask: $call"
        }
    }
}

Describe 'CONSENT-SPLIT-1: the Azure half is on the screen before the directory can fail' {

    It 'the directory read is the LAST thing start() does' {
        # The order IS the fix. It used to be the first act of the page.
        $appShown = $script:code.IndexOf("`$('#app').style.display = 'block'")
        $dirRead = $script:code.IndexOf('await loadDirectory()')
        $appShown | Should -BeGreaterThan 0
        $dirRead | Should -BeGreaterThan 0
        $dirRead | Should -BeGreaterThan $appShown -Because 'the page must be drawn before the directory is asked'
    }

    It 'and the Azure scopes are loaded before it too' {
        $scopes = $script:code.IndexOf('loadScopes()')
        $dirRead = $script:code.IndexOf('await loadDirectory()')
        $scopes | Should -BeGreaterThan 0
        $dirRead | Should -BeGreaterThan $scopes
    }

    It 'the first directory read is SILENT, so arriving cannot throw a person at Entra' {
        # `graph` defaults to interactive so every call a person made by
        # pressing something is unchanged. Only the load passes false.
        # SILENT BY DEFAULT, the rule POPUP-2 established for `arm` on this same
        # page: an interactive default puts the bug back, because a call that
        # forgets the argument asks while the page is loading. Since POPUP-3
        # that navigates the page away rather than opening a blocked window.
        $script:code | Should -Match 'async function graph\(method, path, body, interactive = false\)'
        $script:code | Should -Match 'async function loadDirectory\(interactive = false\)'
        # The read inside loadDirectory passes its own flag through, rather
        # than taking graph's interactive default.
        $body = [regex]::Match($script:code, '(?s)async function loadDirectory\(.*?\n\}').Value
        $body | Should -Match 'servicePrincipals'
        $body | Should -Match ', null, interactive\)'
    }

    It 'a refusal is caught rather than thrown at the page' {
        # `boot().catch(fail)` paints the whole page with the error, which is
        # what produced a screen holding one word.
        $body = [regex]::Match($script:code, '(?s)async function loadDirectory\(.*?\n\}').Value
        $body | Should -Not -BeNullOrEmpty
        $body | Should -Match 'catch'
        $body | Should -Match 'return false'
    }
}

Describe 'CONSENT-SPLIT-1: a refusal is a sentence and a button, not an error' {

    It 'the two cards that cannot work are taken off the screen' {
        $body = [regex]::Match($script:code, '(?s)async function loadDirectory\(.*?\n\}').Value
        $body | Should -Match "#who-table'\)\.style\.display = 'none'"
        $body | Should -Match "#add-card'\)\.style\.display = 'none'"
    }

    It 'and put back when the directory answers' {
        # A one-way hide would leave an administrator who connects successfully
        # looking at an empty card.
        $body = [regex]::Match($script:code, '(?s)async function loadDirectory\(.*?\n\}').Value
        $body | Should -Match "#who-table'\)\.style\.display = ''"
        $body | Should -Match "#add-card'\)\.style\.display = ''"
    }

    It 'the message says the other card still works' {
        # THE SENTENCE THAT WAS MISSING. Without it a person reads a refusal and
        # concludes the product is shut, which is what happened.
        $ux = [regex]::Match($script:raw, "dirBlockedWhy:\s*'([^']*)'").Groups[1].Value
        $ux | Should -Not -BeNullOrEmpty
        $ux | Should -Match '(?i)card below still works'
        $ux | Should -Match '(?i)no user can approve'
    }

    It 'and it says owning the subscription is not the same thing' {
        # The trap the owner hit: subscription ownership is authority over
        # RESOURCES and carries nothing in the DIRECTORY.
        $ux = [regex]::Match($script:raw, "dirBlockedWhy:\s*'([^']*)'").Groups[1].Value
        $ux | Should -Match '(?i)owning the subscription'
    }

    It 'the button asks once, through the shared guard' {
        # A redirect that is refused returns to the page. Asking again on that
        # return is a loop nobody can stop, and the directory may never say yes.
        $body = [regex]::Match($script:code, '(?s)async function loadDirectory\(.*?\n\}').Value
        $body | Should -Match 'dir-connect'
        $body | Should -Match 'loadDirectory\(true\)'
        # POPUP-3 holds the one-ask rule; this must not grow a second one.
        $script:code | Should -Not -Match 'acquireTokenPopup|loginPopup'
    }
}

Describe 'CONSENT-STUCK-1: a refused consent leaves nothing dead on the screen' {
    # Measured: the owner pressed Connect to Azure, his directory refused, and
    # the page was then stuck - the button did nothing on a second press and the
    # Subscription picker was an empty box above a grant button that could not
    # work. A control that dies silently is rule 11's trap.

    It 'every connect button comes back after a failure' {
        # Disabling on click and never restoring is what made it dead.
        foreach ($id in @('dir-connect', 'scope-connect')) {
            $script:code | Should -Match "$id[\s\S]{0,400}disabled = false" -Because "$id must be usable again"
        }
    }

    It 'the grant form is hidden when there is no Azure access, and shown when there is' {
        # An empty picker over a dead button reads as a broken page.
        $body = [regex]::Match($script:code, '(?s)async function loadScopes\(.*?\n\}').Value
        $body | Should -Match "#scope-add'\)\.style\.display = 'none'"
        $body | Should -Match "#scope-add'\)\.style\.display = ''"
    }

    It 'a refusal is explained rather than printed raw' {
        # It showed the exception text. VmfHelp.explain turns the directory's
        # codes into sentences (CONSENT-UX-1).
        $body = [regex]::Match($script:code, '(?s)async function loadScopes\(.*?\n\}').Value
        $body | Should -Match 'VmfHelp\.explain\('
        $body | Should -Not -Match 'host\.textContent = err\.message'
    }

    It 'and the card warns that a directory may refuse this outright' {
        $ux = [regex]::Match($script:raw, "scopeConnectRefused:\s*'([^']*)'").Groups[1].Value
        $ux | Should -Match '(?i)admin approval'
        # MANUAL-REVIEW-1 (hard rule 12): the page sends nobody to a command line.
        $ux | Should -Not -Match '(?i)command line'
    }
}
