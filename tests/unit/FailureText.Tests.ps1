#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# FAIL-TEXT-1 - what a person sees when the thing they asked for is refused.
#
# Found in the RBAC pass, with a second identity that had the app role but
# not the Azure one: that viewer signed in and got a 403 at once.
#
# What the page showed was `list : HTTP 403`, on the FIRST SCREEN a new
# person ever sees - engine text that names neither what was refused nor what
# to ask for. Underneath it sat an empty blue pill: a styled button with no
# label, because its text was set inside render() and render() only runs after
# the load that had just thrown.
#
# NEITHER IS A PERMISSION BUG. A store 403 is the correct and expected answer
# for somebody holding an app role and no Azure RBAC - the dashboard reads blob
# storage with the VIEWER'S OWN token, so those are two separate grants and
# people are given one without the other constantly. The defect is entirely in
# what the product said about it.
#
# And the right words already existed, on ONE page: the migrations first-run
# panel has explained this exact failure since it was written, while every
# other page printed e.message. Same fault as the navigation bar and the
# signed-in identity before it - shared right up to the point where it was not.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:dash     = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:pages    = @(Get-ChildItem $script:dash -Filter '*.html')
    $script:help     = Get-Content (Join-Path $script:dash 'help.js') -Raw
    $script:index    = (Get-VmfPageSource -Path (Join-Path $script:dash 'index.html'))
}

Describe 'FAIL-TEXT-1: a refusal says what to do about it' {

    It 'the shared bar owns the explanation' {
        $script:help | Should -Match 'function explain\(err\)'
        $script:help | Should -Match 'window\.VmfHelp = \{[^}]*explain'
    }

    It 'a ROLE refusal and a STORE refusal are told apart' {
        # THE TRAP, caught before the owner walked into it. The first version
        # mapped ANY 403 to the storage message - and a role refusal from the
        # facade is also a 403. Somebody with a Viewer role trying to act would
        # have been told they needed Storage Blob Data Reader: a permission
        # they already had, on a thing that was not the problem.
        #
        # The facade's own refusal already names the roles that WOULD work and
        # the ones the person holds, so it is rewritten into plain words rather
        # than thrown away.
        $script:help | Should -Match 'requires one of'
        $script:help | Should -Match 'Your role does not allow this'
        $script:help | Should -Match 'ROLE_WORDS'
        # and the role rule is tried BEFORE the storage one, or the storage
        # rule swallows it again.
        $roleAt  = $script:help.IndexOf('requires one of')
        $storeAt = $script:help.IndexOf('AuthorizationPermissionMismatch')
        $roleAt | Should -BeGreaterThan 0
        $roleAt | Should -BeLessThan $storeAt -Because 'the specific rule must be tried first'
    }

    It 'and it says which roles in the words the roles page uses' {
        # "It needs Operator or Administrator" - not Vmf.Operator, which is an
        # identifier and not a thing anybody was offered on the Admin page.
        $script:help | Should -Match "'Vmf\.Operator': 'Operator'"
        $script:help | Should -Match "'Vmf\.Admin': 'Administrator'"
    }

    It 'and a refused read names the permission and who grants it' {
        # The three things somebody stuck on this screen needs: that they ARE
        # signed in, which permission is missing, and where it is given.
        #
        # STORE-READ-1 changed the answer to the third one, and made it a
        # better screen. The missing permission used to be Storage Blob Data
        # Reader, granted in Azure by somebody who may not even be in the room
        # - so the sentence had to end "granted outside this app", which is a
        # dead end. The records are read by the service now, so the only thing
        # that can refuse a reader is their role in this tool, and the Admin
        # page gives that. The sentence names a screen instead of a dead end.
        $script:help | Should -Match '(?i)you are signed in'
        $script:help | Should -Match '(?i)on the Admin page'
        # Only the SENTENCES, not the comments - the comment above the rule
        # still says what the sentence used to be and why it changed, and that
        # history is worth keeping.
        $said = (Get-VmfCodeOnly -Language CStyle -Text $script:help)
        $said | Should -Not -Match 'Storage Blob Data Reader' -Because 'no reader needs an Azure data role any more'
        # The store pattern is NARROWER now than it was. It used to be a bare
        # /403/, which swallowed the facade's role refusals too - the very
        # trap the test above exists for.
        $script:help | Should -Match 'HTTP 40\[13\]'
        $script:help | Should -Match 'AuthorizationPermissionMismatch'
        # The STORE rule must not be a bare 403 - that was the version that
        # swallowed role refusals. The ACTION catch-all legitimately is one,
        # so the check names the store rule rather than the pattern.
        $storeRule = [regex]::Match($script:help, '(?s)readOnly: true,.{0,80}?when: (/[^/]+/)').Groups[1].Value
        $storeRule | Should -Not -BeNullOrEmpty
        $storeRule | Should -Not -Match '^/403' -Because 'a bare 403 also matches a role refusal'
    }

    It 'no page shows a raw error object where a person can read it' {
        # `$('#err').textContent = e.message` is the shape that shipped
        # `list : HTTP 403`. A page composing its OWN sentence is fine - that
        # is the opposite of this fault - so only the raw form is caught.
        $bad = foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            $hits = [regex]::Matches($text, "\`$\('#err'\)\.textContent = (e\.message \?\? e|e\.message|String\(e\.message \?\? e\))\s*[;\r\n]")
            if ($hits.Count) { "$($p.Name) ($($hits.Count))" }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'a raw error is engine text on a screen a customer reads'
    }

    It 'every page that reads the store routes its failures through it' {
        $bad = foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            # STORE-READ-1: the precondition used to be "this page calls blob
            # storage". No page does any more - they call the facade - and the
            # "tests that cannot fail" gate caught this the moment that became
            # true. The rule still applies; only the marker for "reads the
            # store" changed.
            if ($text -notmatch 'VmfHelp\.store(List|Blob)\(') { continue }
            if ($text -notmatch 'VmfHelp\.explain\(') { $p.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'a page that can be refused a read must be able to explain it'
    }
}

Describe 'FAIL-TEXT-2: an action never blames Azure RBAC' {

    It 'the storage sentence is marked read-only' {
        # Found under Create project: no action in the UX may show this type
        # of message, whatever the role. It must say which app role is
        # required, not name an underlying Azure permission.
        #
        # It is a correctness rule, not a wording preference. Reading the
        # records CAN fail on Azure RBAC. An action goes through the facade,
        # which refuses on APP ROLE and never touches the viewer's storage
        # permission - so naming storage there is always false, and sends
        # somebody to fix a permission that is not the problem.
        $script:help | Should -Match '(?s)readOnly: true,\s*?
\s*when: /HTTP 40'
        $script:help | Should -Match 'if \(f\.readOnly && forAction\) \{ continue; \}'
    }

    It 'and an action has its own answer for a refusal the facade did not explain' {
        $script:help | Should -Match 'actionOnly: true'
        $script:help | Should -Match 'Ask a user with the Administrator role for the role that covers it'
    }

    It 'a sign-in failure is not reported as a role problem' {
        # 401 means the token was not accepted. The action catch-all would
        # otherwise tell somebody with an expired session to go and ask for a
        # role they already have.
        # RETRY-GATE-1: the first 'actionOnly: true' is no longer the catch-all -
        # the anchored 409: and 400: rules sit above the 401 rule, so a refusal
        # that names a machine like web401 keeps its words. The catch-all is the
        # 403/forbidden rule, found by its own text.
        $roleCatchAll = $script:help.IndexOf('actionOnly: true, when: /403|forbidden/i')
        $roleCatchAll | Should -BeGreaterThan 0
        $signIn = $script:help.IndexOf("when: /401/")
        $signIn | Should -BeGreaterThan 0
        $signIn | Should -BeLessThan $roleCatchAll -Because '401 is sign-in, not role'
    }

    It 'EVERY try block that calls the facade reports with the action explainer' {
        # The rule, enforced rather than described. projects.html shipped the
        # storage sentence under Create project because one fail() served both
        # the page load and the button.
        $bad = foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            foreach ($m in [regex]::Matches($text, '(?s)try \{(.*?)\}\s*?
?\s*catch \((\w+)\) \{(.*?)\}')) {
                $body = $m.Groups[1].Value
                $handler = $m.Groups[3].Value
                if ($body -notmatch 'await (api|apiPost|apiFetch|graph|arm)\(') { continue }
                if ($handler -match 'VmfHelp\.explain\(' -or $handler -match '(?<![A-Za-z])fail\(') {
                    "$($p.Name): $($handler.Trim().Substring(0, [math]::Min(60, $handler.Trim().Length)))"
                }
            }
        }
        $bad -join ' | ' | Should -BeNullOrEmpty -Because 'a facade call refused on ROLE must never mention storage'
    }

    It 'and every page that acts has the action reporter to use' {
        $bad = foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            if ($text -notmatch 'await (api|apiPost|apiFetch|graph|arm)\(') { continue }
            if ($text -notmatch 'VmfHelp\.explainAction\(') { $p.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'FAIL-TEXT-1: a failure does not leave a half-drawn page' {

    It 'the front door labels its own controls BEFORE it asks for data' {
        # The empty blue pill. #assess-btn was styled and unlabelled because
        # its text lived in render(), which never ran. Anything that does not
        # depend on the data is drawn before the data is requested.
        $script:index | Should -Match 'function chrome\(\)'
        $script:index | Should -Match "(?s)function chrome\(\).*?assess-btn'\)\.textContent"
        # chrome() runs in start() BEFORE the try that loads.
        $script:index | Should -Match '(?s)async function start\(\).*?chrome\(\);.*?try \{ await load\(\)'
    }

    It 'and render still draws it, so a successful load is unchanged' {
        $script:index | Should -Match '(?s)function render\(\) \{\s*chrome\(\);'
    }
}
