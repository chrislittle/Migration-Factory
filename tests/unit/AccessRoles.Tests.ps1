#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ROLE-EDIT-1 - changing what somebody holds, and knowing who they are.
#
# Found 2026-09-02: the Admin page had no way to edit the roles a user holds.
# And two identical rows were two different Entra ID users with the same
# first and last name.
#
# The two compound. The table could take a role AWAY - every pill
# has its own remove - but the only way to ADD one was to search the directory
# for a person already on the screen. And with two accounts sharing a display
# name, the row you were about to change was not identifiable: the grouping was
# always correct (it keys on principal id, so they were two rows all along),
# but the SCREEN showed the same four words twice.
#
# A row you cannot identify is a row you cannot safely change, and a table that
# can only remove is half a control.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:access   = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.html'))
}

Describe 'ROLE-EDIT-1: who the row is' {

    It 'groups by principal id, not by name' {
        # Two people with one display name are two principals. Keying on the
        # name would merge their roles into one row and show each of them the
        # other's access.
        $script:access | Should -Match 'byPrincipal\.has\(a\.principalId\)'
        $script:access | Should -Match 'byPrincipal\.set\(a\.principalId'
    }

    It 'shows the sign-in name under the display name' {
        $script:access | Should -Match 'signIn'
        $script:access | Should -Match 'userPrincipalName'
    }

    It 'reads those names in ONE call, not one per row' {
        # A directory with fifty people would otherwise make fifty requests to
        # render a table.
        $script:access | Should -Match "graph\('POST', 'directoryObjects/getByIds'"
    }

    It 'and a failure costs the sign-in names, not the page' {
        # The table is still the only way to see who holds what. It must render
        # when the lookup is refused.
        $m = [regex]::Match($script:access, "(?s)directoryObjects/getByIds.*?catch \(e\) \{[^\n]*")
        $m.Success | Should -BeTrue -Because 'the lookup must be guarded'
        $m.Value | Should -Not -Match 'fail\(e\)'
    }
}

Describe 'ROLE-EDIT-1: changing what they hold' {

    It 'offers only the roles that would ADD something' {
        # Offering a role somebody holds is an action that does nothing, and
        # Graph answers it with a conflict.
        #
        # ROLE-2 made the rule stricter rather than replacing it: a role that
        # is COVERED by one they hold also adds nothing, so an Operator is no
        # longer offered Viewer and an Administrator is offered nothing at all.
        # Administrator is everything, so a person who picks it needs no
        # other role.
        $script:access | Should -Match 'const held = new Set\(p\.roles\.map'
        $script:access | Should -Match '!held\.has\(r\.id\) && !coveredIds\.has\(r\.id\)'
    }

    It 'says so plainly when there is nothing left to add' {
        # ROLE-2/3 replaced the string this pinned. It used to read "They
        # already hold every role" for anybody with the full set - a fact about
        # the LIST rather than about the person, and wasted on somebody who
        # only ever needed Administrator. The statement told them nothing.
        #
        # The rule survives, the sentence changed: say the useful thing, and
        # only when there is a useful thing to say.
        $script:access | Should -Match 'roleAllCovered'
        $script:access | Should -Match 'Administrator covers everything'
    }

    It 'grants to THAT row, by principal id' {
        # data-to carries the principal, so the button cannot grant to whoever
        # happens to be first in the table.
        $script:access | Should -Match 'data-to="\$\{esc\(p\.id\)\}"'
        $script:access | Should -Match 'principalId: b\.dataset\.to'
    }

    It 'and re-reads the table afterwards' {
        # The same class of defect as the stuck project delete: a change the
        # screen does not show reads as a change that did not happen.
        # A WINDOW after the handler starts. `data-grant` also appears in the
        # markup that draws the buttons, and matching from there captured the
        # template instead of the code.
        $i = $script:access.IndexOf("tb.querySelectorAll('[data-grant]')")
        $i | Should -BeGreaterThan -1 -Because 'the grant handler must exist'
        $script:access.Substring($i, 600) | Should -Match 'loadAssignments\(\)'
    }

    It 'and the person can change their mind' {
        # Adding a role had no way to cancel the add. An action must have a
        # way to cancel it: that is normal UX navigation, and this defect had
        # come back several times.
        #
        # ONE button with two states - it opens the choices, and while they are
        # showing it says Cancel. Escape closes it too, because that is what a
        # person tries first.
        $script:access | Should -Match 'data-close="\$\{esc\(UX\.addRoleCancel\)\}"'
        $script:access | Should -Match 'b\.textContent = b\.dataset\.close'
        $script:access | Should -Match "e\.key === 'Escape'"
        $script:access | Should -Match 'closeRoleMenus'
    }

    It 'one menu open at a time' {
        # Two open menus in one table is two lists of buttons with nothing
        # saying which row either belongs to.
        $script:access | Should -Match 'closeRoleMenus\(\);\s*//'
    }

    It 'and the control does not wrap inside its cell' {
        # "+ Add a role" was breaking across two lines and splitting its own
        # box, the same way "Plan a migration" did.
        # DARK-1: the CSS moved into src/dashboard/app.css. Same rule, one home.
        $appCss = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'app.css') -Raw
        # DARK-1: the nowrap moved to `.btn`. A button label that breaks
        # mid-phrase splits its own box, and that is true of every button,
        # not of this cell - the same defect was reported three times in
        # three places. Asserting it here again would be asserting a COPY.
        $appCss | Should -Match '(?m)^\.btn \{[^}]*white-space:nowrap' `
            -Because 'the button owns this, so + Add a role cannot lose it'
    }

    It 'still does everything AS THE SIGNED-IN PERSON' {
        # PERM-2: no service identity may change access. The page calls Graph
        # with the admin's own delegated token, and that must not drift.
        #
        # CONSENT-SPLIT-1 changed HOW the token is asked for, not WHOSE it is.
        # It used to read `getToken(GRAPH_SCOPES, true)` - always interactive.
        # Reading is silent now and only the four calls that change something
        # ask interactively, the rule `arm` has followed since POPUP-2. The
        # property this test exists for is unchanged: a delegated token for the
        # signed-in account, never a service identity.
        $script:access | Should -Match 'async function graph'
        $script:access | Should -Match 'getToken\(GRAPH_SCOPES, interactive\)'
        # And the account is the signed-in one - `getToken` builds its request
        # from `account`, so a service identity cannot get in this way.
        $script:access | Should -Match 'const req = \{ scopes, account \}'
    }
}

# LEAK-2: a listener on `document` outlives the markup that prompted it.
#
# loadAssignments() runs again after every grant, tidy, removal and search, and
# it used to add a document-level Escape handler each time and remove none - so
# the count grew for the life of the tab, and every one of the accumulated
# copies swept the whole table on every keypress. The table's row count is the
# number of principals holding a role, which the directory decides.
#
# help.js:476 already guarded exactly this shape for the nav; the guard was
# never applied here.
Describe 'LEAK-2: the access page wires its Escape key once, not once per render' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        # COMMENT-TRAP-1: the page now EXPLAINS this rule in prose at both ends
        # - inside loadAssignments and beside the one-time wiring - so a
        # whole-file match finds the explanation and passes either way.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:accessCode = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.html')
        $script:loadFn = [regex]::Match($script:accessCode,
            '(?s)async function loadAssignments\(\).*?\n\}').Value
        $script:startFn = [regex]::Match($script:accessCode,
            '(?s)async function start\(\).*?\n\}').Value
    }

    It 'the render path adds NO document-level listener' {
        $script:loadFn | Should -Not -BeNullOrEmpty
        $script:loadFn | Should -Not -Match 'document\.addEventListener' `
            -Because 'loadAssignments runs after every grant, tidy, removal and search'
    }

    It 'and start() adds the Escape handler exactly once' {
        $script:startFn | Should -Not -BeNullOrEmpty
        @([regex]::Matches($script:startFn, 'document\.addEventListener\(''keydown''')).Count |
            Should -Be 1 -Because 'rule 11 - a menu that opens must offer a way back'
        $script:startFn | Should -Match 'closeRoleMenus\(\)'
    }

    It 'closeRoleMenus survives a rebuild, because it re-reads the table' {
        # The handler is wired once for the page; the table it acts on is
        # rebuilt by every loadAssignments. Closing over one render's copy
        # would leave the key acting on a table nobody is looking at.
        $script:accessCode | Should -Match '(?s)function closeRoleMenus\(\) \{.*?\$\(''#who-table tbody''\)'
    }
}
