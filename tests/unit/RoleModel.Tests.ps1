#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ROLE-2 - the roles page describes the roles the facade actually enforces.
#
# Five faults were found at once: Administrator was described as "everything
# above" on a row with no order; picking Administrator did not cover the other
# roles, though it holds everything; no role was checked for this layering; the
# cancel button looked like a role option; and "they already hold every role"
# was a wasted statement when Administrator alone does everything.
#
# All five were the same fault: the page described a LIST rather than a MODEL.
# "Everything above" is a statement about list order, and these are pills on a
# row that has none.
#
# THE MODEL, READ OUT OF THE FACADE'S OWN GATES:
#
#   Administrator  in EVERY Assert-VmfFacadeRole call, plus this page
#   Operator       read + start, pause, resume, fix.  CANNOT sign off a wave
#   Approver       read + sign off a wave.            CANNOT run anything
#   Viewer         read
#
# OPERATOR AND APPROVER ARE SIBLINGS, NOT STEPS - Invoke-VmfFacadeApprove takes
# Approver or Administrator and refuses an Operator, so whoever runs a wave
# cannot also sign it off. That separation is the most important thing about
# these roles and the old wording never mentioned it.
#
# THIS FILE READS BOTH SIDES. A description of a permission model that is not
# checked against the model is a comment, and comments drift.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:access   = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.html'))
    $script:css      = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'app.css') -Raw
    $script:core     = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
    $script:endpoints = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'facade' 'app') -Recurse -Filter 'run.ps1' |
        ForEach-Object { (Get-VmfPageSource -Path $_.FullName) }) -join "`n"
    $script:allGates = [regex]::Matches("$($script:core)`n$($script:endpoints)",
        "AnyOf @\(([^)]*)\)") | ForEach-Object { $_.Groups[1].Value }
}

Describe 'ROLE-2: the page describes the model the facade enforces' {

    It 'found the gates, or this file proves nothing' {
        @($script:allGates).Count | Should -BeGreaterThan 15
    }

    It 'Administrator really is in every gate, which is why it needs no others' {
        # The claim the page now makes. If a single gate ever omits Admin, the
        # page would be telling somebody they have everything when they do not.
        $without = @($script:allGates | Where-Object { $_ -notmatch "Vmf\.Admin" })
        $without -join ' | ' | Should -BeNullOrEmpty -Because 'Administrator is offered as covering everything'
    }

    It 'and Viewer adds nothing to Operator or Approver, which is why it is not offered to them' {
        # Every gate that admits Viewer must also admit both of the others, or
        # "Already covered by the Operator role" would be a lie.
        $viewerGates = @($script:allGates | Where-Object { $_ -match "Vmf\.Viewer" })
        $viewerGates.Count | Should -BeGreaterThan 0
        foreach ($g in $viewerGates) {
            $g | Should -Match "Vmf\.Operator" -Because "a Viewer-readable gate must admit an Operator: $g"
            $g | Should -Match "Vmf\.Approver" -Because "a Viewer-readable gate must admit an Approver: $g"
        }
    }

    It 'an Operator genuinely CANNOT sign off a wave - the separation is real' {
        # The thing the page now says out loud. If this ever changes, the
        # wording is wrong and this test is how anyone finds out.
        $approve = [regex]::Match($script:core,
            '(?s)function Invoke-VmfFacadeApprove\b.*?AnyOf @\(([^)]*)\)').Groups[1].Value
        $approve | Should -Not -BeNullOrEmpty
        $approve | Should -Match 'Vmf\.Approver'
        $approve | Should -Match 'Vmf\.Admin'
        $approve | Should -Not -Match 'Vmf\.Operator' -Because 'whoever runs a wave must not also sign it off'
    }

    It 'the page states that separation rather than implying a ladder' {
        $script:access | Should -Match '(?i)Cannot sign off a wave'
        $script:access | Should -Match '(?i)Cannot start, pause or stop anything'
        # The ROLE WORDS, not the whole file: a comment explaining why the old
        # phrase was wrong must not itself trip the rule against it.
        $words = [regex]::Match($script:access, '(?s)roleWords: \{(.*?)
  \},').Groups[1].Value
        $words | Should -Not -BeNullOrEmpty
        $words | Should -Not -Match 'Everything above' -Because 'there is no "above" in a row of pills'
    }

    It 'and the coverage table matches the gates' {
        $script:access | Should -Match "roleCovers:"
        $script:access | Should -Match "'Vmf\.Admin':\s*\['Vmf\.Viewer', 'Vmf\.Approver', 'Vmf\.Operator'\]"
        $script:access | Should -Match "'Vmf\.Operator':\s*\['Vmf\.Viewer'\]"
        $script:access | Should -Match "'Vmf\.Approver':\s*\['Vmf\.Viewer'\]"
    }
}

Describe 'ROLE-3: the install makes ONE administrator, not one of everything' {

    # Found 2026-09-08 on the Admin page after an install: the first user held
    # all 4 roles, with a note that the other 3 were not needed and could be
    # removed. The deployment gave the initial admin user every role:
    # tools/Deploy-VmfFacade.ps1 looped over all four role ids.
    # Nothing broke when three were removed, because ROLE-2 above proves
    # Administrator sits in every gate - so the other three carried no
    # permission the user did not already hold. They were three objects in the
    # directory that a person had to read, judge and remove by hand, on the
    # one account every install creates.
    #
    # Worse than untidy: the Admin page asks a person to grant the SMALLEST
    # role that does the job, and the install did the opposite on the first
    # account anybody sees.
    #
    # This reads the SCRIPT, because the grant is an az call that no unit test
    # may make.

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:bootstrap = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfFacade.ps1') -Raw
        $script:granted = @([regex]::Matches($script:bootstrap,
            "appRoleId = \`$RoleIds\['([^']+)'\]") | ForEach-Object { $_.Groups[1].Value })
    }

    It 'grants exactly one app role' {
        ($script:granted -join ', ') | Should -Be 'Vmf.Admin' -Because 'the first account needs entry, not every role'
    }

    It 'never loops over the role map again' {
        # The shape of the defect, named so it cannot come back quietly. The
        # map itself stays - it is what FacadeCore.Tests.ps1 checks the
        # template against - but iterating it is what granted four.
        $script:bootstrap | Should -Not -Match 'foreach \(\$\w+ in .*\$RoleIds' -Because 'granting every role in the map is the defect ROLE-3 fixed'
        $script:bootstrap | Should -Not -Match '(?i)assign all roles'
    }

    It 'and the role it grants is one the facade admits everywhere' {
        # THE REAL INVARIANT, and why one role is enough. If a gate is ever
        # written without Administrator, a fresh install would produce an
        # account that cannot reach part of its own tool - and this test says
        # so before anybody installs it.
        $without = @($script:allGates | Where-Object { $_ -notmatch [regex]::Escape($script:granted[0]) })
        $without -join ' | ' | Should -BeNullOrEmpty -Because "the install grants only $($script:granted[0]), so every gate must admit it"
    }

    It 'a publish does not remove role assignments an install already made' {
        # An existing deployment keeps the three extra roles it was given.
        # Deleting them from a CODE PUBLISH would remove access behind an
        # operator's back, and a publish is not where that decision belongs.
        # The Admin page draws a covered role quiet, says what covers it, and
        # removes it on one click - which is the path hard rule 12 asks for.
        $script:bootstrap | Should -Not -Match 'appRoleAssignments/'
        $script:access | Should -Match 'roleAllCovered'
        $script:access | Should -Match 'deadRoles'
    }
}

Describe 'ROLE-GATE-1: no role means no entry' {

    It 'every page gates on holding a role' {
        # Found on the last step of the RBAC pass (step 9): a user with no
        # role could sign in and see things.
        #
        # The revocation worked - both the app role and the store read were
        # gone. What did not stop was ARRIVING. Five of the eight pages never
        # looked at app roles at all, so signing in needed no role and whether
        # anything appeared depended entirely on Azure RBAC.
        $pages = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.html')
        $bad = foreach ($p in $pages) {
            $t = (Get-VmfPageSource -Path $p.FullName)
            if ($t -notmatch 'VmfHelp\.gateOnRole\(') { $p.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'signing in is not the same as having access'
    }

    It 'every page that carries the gate line DECLARES every name the line reads (ADMIN-1)' {
        # A regression broke the Admin page. The gate
        # line was pasted into eight pages. Seven declare DEMO_MODE; the Admin
        # page has no demo mode and never did, so on that page the first line
        # of start() was a ReferenceError - caught by boot() and shown as a red
        # bar, with the whole page behind it dead. The test above only checked
        # the line was PRESENT, which is how it passed while the page failed.
        #
        # A name is declared or it is not; this has no judgement in it.
        $pages = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.html')
        $bad = foreach ($p in $pages) {
            $t = (Get-VmfPageSource -Path $p.FullName)
            if ($t -notmatch 'VmfHelp\.gateOnRole\(') { continue }
            foreach ($name in 'DEMO_MODE', 'cfg', 'getToken', 'msalApp') {
                $declared = $t -match "(?m)^\s*(const|let|var)\s+$name\b" -or
                            $t -match "(?m)^\s*(async\s+)?function\s+$name\s*\(" -or
                            $t -match "(?m)^\s*(let|var)\s+[^;]*\b$name\b"
                if (-not $declared) { "$($p.Name) reads $name and never declares it" }
            }
        }
        $bad -join ' | ' | Should -BeNullOrEmpty -Because 'an undeclared name is a ReferenceError on the first line of start()'
    }

    It 'and it gates BEFORE the page loads anything' {
        $pages = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.html')
        foreach ($p in $pages) {
            $t = (Get-VmfPageSource -Path $p.FullName)
            $t | Should -Match '(?s)async function start\(\)\s*\{[^}]{0,600}?gateOnRole' `
                -Because "$($p.Name) must ask before it shows anything"
        }
    }

    It 'the roles come from the API token, which is the only one that carries them' {
        # Reading blob needs a STORAGE-scoped token, and that token has no app
        # roles in it at all - which is why five pages could not have checked
        # even if they had tried.
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Match 'access_as_user'
        $help | Should -Match 'claims\.roles'
    }

    It 'and UNKNOWN is not "no role"' {
        # A deployment with no facade has no app roles to hold. Gating on an
        # unanswerable question would lock everybody out of a dashboard that is
        # working exactly as configured.
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Match 'if \(!cfg \|\| !cfg\.apiAppId\) \{ return \{ checked: false'
        $help | Should -Match 'if \(!checked \|\| roles\.length\) \{ return true; \}'
    }

    It 'the panel says what to ask for, and where' {
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Match 'noRoleTitle:'
        $help | Should -Match '(?i)administrator can add one on the Admin page'
    }
}

Describe 'ROLE-GATE-3: being turned away is not being trapped' {

    It 'the no-access panel offers a way out' {
        # Once the gate worked, the no-access panel had no sign-out: the only
        # way to get unstuck was to close the browser.
        #
        # That is not acceptable. Almost everybody who lands here is signed in as the WRONG
        # ACCOUNT - having a second identity is the whole reason to be here -
        # and the one thing they need is to leave. Closing the browser is not
        # a control. CLAUDE.md rule 11: anything that opens offers a way back.
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $gate = [regex]::Match($help, '(?s)async function gateOnRole.*?\n  \}').Value
        $gate | Should -Not -BeNullOrEmpty
        $gate | Should -Match 'signOut' -Because 'the screen that says you are stuck must be the one that unsticks you'
        $gate | Should -Match 'installRight\(\)' -Because 'the bar is built after this point on every page'
        $gate | Should -Match 'identity\(acct\)' -Because 'identity() is what reveals the sign-out button'
    }

    # SIGNOUT-1, FOUND BY MUTATION. The behaviour of signOut is proved by
    # running it (tests/js/sign-out.test.js), but those tests hand it the
    # fallback app directly, so deleting the line in gateOnRole that CAPTURES
    # that app broke nothing they assert. Without the capture the gate's button
    # is dead again on the three pages that gate before they install.
    #
    # Position is the whole point, so this reads the source - with comments
    # stripped, because the code above it now explains this rule in prose and a
    # whole-file match would find the explanation (COMMENT-TRAP-1).
    It 'the gate keeps the MSAL app BEFORE it can return early, so its sign-out works' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js')
        $gateCode = [regex]::Match($code, '(?s)async function gateOnRole.*?\n  \}').Value
        $gateCode | Should -Not -BeNullOrEmpty

        $capture = $gateCode.IndexOf('gateMsal = msalApp')
        $capture | Should -BeGreaterThan -1 -Because 'signOut has no other way to reach MSAL on a page that gates before it installs'

        # Every way out of gateOnRole must come after the capture, or the gate
        # screen is reached with nothing to sign out through.
        $firstReturn = $gateCode.IndexOf('return true')
        $firstReturn | Should -BeGreaterThan -1
        $capture | Should -BeLessThan $firstReturn -Because 'a capture after the early return never runs for the person being gated'

        # And it must not sit behind the role check either.
        $rolesCall = $gateCode.IndexOf('await myRoles(')
        $rolesCall | Should -BeGreaterThan -1
        $capture | Should -BeLessThan $rolesCall -Because 'myRoles can throw, and the button is still needed then'
    }

    It 'and it says which account they are signed in as' {
        # The fact that ends the confusion. Somebody turned away is usually
        # signed in as the wrong person, and this is the question they are
        # really asking when the app says no.
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Match 'noRoleWho:'
        $help | Should -Match '(?i)signed in as \{who\}'
        $gate = [regex]::Match($help, '(?s)async function gateOnRole.*?\n  \}').Value
        $gate | Should -Match 'TEXT\.noRoleWho' -Because 'a string nothing renders is not a message'
    }
}

Describe 'ROLE-GATE-2: the refusal to issue the token IS the answer' {

    It 'AADSTS50105 is read as "no role", not as "cannot tell"' {
        # The gate shipped and step 9 still showed the old storage message
        # where the no-access panel should have been.
        #
        # The gate was there and running. But vmf-api has
        # appRoleAssignmentRequired = true, so Entra will not issue that token
        # AT ALL to somebody with no role - AADSTS50105. My catch treated every
        # failure as unknown, and unknown lets people through.
        #
        # "Unknown is not no" is the right rule and I applied it too widely.
        # That refusal is not silence: it is Entra answering the question in
        # the only way it can, and reading it as unknown reopened the exact
        # hole the gate was built to close.
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Match 'AADSTS50105'
        $help | Should -Match '(?s)AADSTS50105[^}]*?return \{ checked: true, roles: \[\] \}'
    }

    It 'and it reads EVERY field of the error, not the first one set' {
        # The bug inside the fix, found in the browser driving the real gate.
        # MSAL sets errorCode to 'interaction_required' and puts AADSTS50105 in
        # errorMessage, so `errorCode || errorMessage` reads the generic word
        # and never sees the code that carries the answer - and the gate failed
        # open on precisely the error it had just been written to catch.
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Not -Match 'e\.errorCode \|\| e\.errorMessage'
        $help | Should -Match '(?s)const why = \[.*?errorCode.*?errorMessage.*?\.join'
    }

    It 'and a failure that really is unknown still lets people through' {
        # Offline, popup blocked, no facade. Locking somebody out on a question
        # that could not be asked is the other way to get this wrong.
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Match '(?s)AADSTS50105[\s\S]{0,600}?return \{ checked: false, roles: \[\] \}'
    }

    It 'the role check never opens a popup' {
        # Every page's getToken falls back to acquireTokenPopup. Asking whether
        # somebody holds a role must not be an interaction - a person with no
        # role would get an Entra error window thrown at them before the panel
        # that explains it.
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Match 'acquireTokenSilent'
        $help | Should -Match 'async function myRoles\(cfg, getToken, msalApp\)'
    }

    It 'and every page hands over its MSAL app so it can be silent' {
        $pages = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.html')
        $bad = foreach ($p in $pages) {
            $t = (Get-VmfPageSource -Path $p.FullName)
            if ($t -notmatch 'gateOnRole\(cfg, getToken, msalApp\)') { $p.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'without it the check falls back to a popup'
    }
}

Describe 'ROLE-2: the page offers only what would add something' {

    It 'a role already covered is not offered' {
        $script:access | Should -Match 'coveredIds'
        $script:access | Should -Match '!held\.has\(r\.id\) && !coveredIds\.has\(r\.id\)'
    }

    It 'and the line about holding everything says something useful, or nothing' {
        # It used to read "They already hold every role" for anybody with the
        # full set - a fact about the LIST, not about the person, and wasted on
        # somebody who only ever needed Administrator.
        $script:access | Should -Match 'roleAllCovered:'
        $script:access | Should -Match 'Administrator covers everything'
        $script:access | Should -Match "held\.has\(idOf\('Vmf\.Admin'\)\)"
    }
}

Describe 'ROLE-2: the cancel is not a role, and nobody is left half-granted' {

    It 'the control that opens the menu is styled apart from the choices' {
        $script:access | Should -Match 'class="btn ghost addcancel"'
        $script:css | Should -Match '\.p-access \.addrole \.addcancel \{'
        $script:css | Should -Match '\.p-access \.rolemenu \{[^}]*border-left'
    }

    It 'nobody can be stranded holding a role that does not work yet' {
        # Did the fix apply to a role assignment made before it (a test user
        # who was already a viewer)? No - a second Azure
        # permission was granted only at the moment a role was GIVEN, so
        # everyone already on the page kept their 403. The answer then was a
        # repair button, because the alternative was asking somebody to remove
        # a live permission and add it back.
        #
        # STORE-READ-1 removed the second permission, so the strand it repaired
        # cannot happen. The rule survives as the thing that makes it
        # impossible: giving a role is ONE call, so it either worked or it
        # visibly failed - there is no half-granted person to find later.
        $script:access | Should -Match 'data-grant=' -Because 'the role menu must still grant'
        $script:access | Should -Match "querySelectorAll\('\[data-grant\]'\)" -Because 'and the control must still be bound'
        $script:access | Should -Not -Match 'data-fixstore=' -Because 'there is nothing left to repair'
        # And the proof it is one call: the two places a role is given each
        # report one outcome, not a composed pair.
        $script:access | Should -Match "flash\('#ok', UX\.roleAdded\)"
        $script:access | Should -Match "flash\('#ok', UX\.added\)"
    }
}
