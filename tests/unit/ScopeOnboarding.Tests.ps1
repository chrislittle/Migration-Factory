#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SCOPE-ADD-1 - onboarding a scope from the app, as the signed-in user.
#
# The app needs an admin function, run as the signed-in user, to onboard more
# scopes from the portal and other tooling. An az command to run elsewhere is
# not an answer: a user must not be sent to separate PowerShell commands
# outside the app (hard rule 12).
#
# The original recommendation, accepted at first and then reversed, was to show the exact command for an administrator to run. The argument
# for it was a real one - an app able to widen its own scope cannot be bounded -
# but it does not lead there, because the access console ALREADY solves it: it
# takes a token as the signed-in user and calls the directory as them. The same
# shape works against Azure. The app never holds the right to grant roles; the
# person does, and the tenant's audit log carries their name.
#
# So these tests are mostly about one property: this must never become
# something the SERVICE does.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:access = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.html'))
    $script:facade = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
    $script:deploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
}

Describe 'SCOPE-ADD-1: it acts as the person, never as the service' {

    It 'asks Azure for a token as the signed-in user' {
        $script:access | Should -Match "management\.azure\.com/user_impersonation"
    }

    It 'the grant is made from the BROWSER, not through the service' {
        # The whole security property. If this ever moves behind the facade,
        # the app itself needs the right to grant roles - and an app that can
        # grant roles can grant itself anything.
        $script:access | Should -Match "arm\('PUT'"
        $script:access | Should -Match 'roleAssignments/'
    }

    It 'and the SERVICE has no endpoint that grants a role' {
        # The guard on the property above: nothing in the facade may acquire
        # this capability quietly later.
        $script:facade | Should -Not -Match 'roleAssignments'
        $script:facade | Should -Not -Match 'roleDefinitions'
    }

    It 'the page is ALLOWED to reach Azure - the policy has to say so' {
        # THIS is what "Failed to fetch" actually was. The Content-Security-
        # Policy in web.config lists every host the pages may call, and adding a
        # new one to the code without adding it there means the browser blocks
        # the request before it leaves - with a message that says nothing about
        # policy. Shipped that way this morning.
        $csp = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'web.config') -Raw
        $csp | Should -Match 'connect-src[^;"]*https://management\.azure\.com'
    }

    It 'and every host the POLICY allows is one something actually fetches' {
        # THE SILENT DIRECTION, and nothing else catches it. A host listed here
        # that no page calls is a permission the browser holds for no reason,
        # and removing the code that used it changes nothing visible - so it
        # stays for ever.
        #
        # FOUND BY THIS: `https://*.blob.core.windows.net` outlived
        # STORE-READ-1 by four changes. The dashboard stopped reading blob
        # storage; the policy went on allowing it. The rule is that a
        # removal must actually remove.
        $csp = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'web.config') -Raw
        $connect = [regex]::Match($csp, 'connect-src([^;"]*)').Groups[1].Value
        # Everything the dashboard ships, not only the pages: the store client
        # and the version read live in help.js.
        $code = (Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Include '*.html', '*.js' -File -Recurse |
            ForEach-Object { (Get-VmfPageSource -Path $_.FullName) }) -join "`n"

        # Hosts nothing fetches by name, each with the reason it is still
        # needed. A category, never "it was here already" - the same discipline
        # REACH-2 uses for an endpoint no screen calls.
        $reasons = [ordered]@{
            'https://login.microsoftonline.com' = 'MSAL signs people in from inside the library, so no page names this host'
            'https://graph.microsoft.com'       = 'the Admin page reads the directory through a helper that builds the URL'
            # CSP-AZUREWEBSITES-1: the service is no longer an https:// source
            # here. The template holds a marker, and the publish writes the
            # exact origin of the apiUrl it gives the page (CspServiceHost.Tests.ps1).
        }
        $unused = foreach ($allowed in ($connect -split '\s+' | Where-Object { $_ -like 'https://*' })) {
            $bare = ($allowed -replace '^https://', '') -replace '^\*\.', ''
            if ($code -match [regex]::Escape($bare)) { continue }
            if ($reasons.Contains($allowed)) { continue }
            "$allowed is allowed and nothing fetches it"
        }
        $unused -join '; ' | Should -BeNullOrEmpty -Because 'a host in this policy is a host the browser may reach'

        # and the exemption list cannot rot either
        foreach ($k in $reasons.Keys) {
            $connect | Should -Match ([regex]::Escape($k)) -Because "$k is exempted but no longer allowed"
        }
    }

    It 'and every host the dashboard pages fetch is in that policy' {
        # The general form: a page that calls a host the policy does not list is
        # broken in the browser and fine everywhere else, so nothing but this
        # catches it.
        $csp = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'web.config') -Raw
        $connect = [regex]::Match($csp, 'connect-src([^;"]*)').Groups[1].Value
        $pages = Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter *.html
        $missing = foreach ($page in $pages) {
            $text = (Get-VmfPageSource -Path $page.FullName)
            foreach ($m in [regex]::Matches($text, 'fetch\(`?https://([a-z0-9.-]+\.[a-z]{2,})')) {
                $host_ = $m.Groups[1].Value
                # 'self' covers the page's own origin; wildcards cover subdomains.
                $covered = $connect -match [regex]::Escape($host_) -or
                           ($connect -match '\*\.' -and ($connect -split '\s+' | Where-Object { $_ -like 'https://`*.*' } |
                                Where-Object { $host_ -like ($_ -replace '^https://', '') }))
                if (-not $covered) { "$($page.Name) fetches $host_" }
            }
        }
        $missing -join '; ' | Should -BeNullOrEmpty -Because 'the browser blocks a host the policy does not list'
    }

    It 'never asks for consent while the page is loading' {
        # SHIPPED BROKEN 2026-08-31. Azure is a SECOND consent, separate from the
        # directory one this page already holds, so the silent acquisition fails
        # and MSAL opens a popup - which the browser blocks, because a popup must
        # follow a click. The card rendered "Failed to fetch" with no way forward.
        # Reading is silent; the consent is a button the operator presses.
        $script:access | Should -Match 'async function loadScopes\(interactive = false\)'
        $script:access | Should -Match 'scopeConnectBtn'
        # And the read must pass that flag through rather than forcing a popup.
        $script:access | Should -Match "arm\('GET', '/subscriptions[^']*', null, interactive\)"
    }

    It 'a 403 is treated as an ANSWER, not a crash' {
        # An administrator who cannot grant at that scope should be told so.
        # Their own 403 is the correct and auditable outcome, and the whole
        # reason this can be done from the browser at all.
        $script:access | Should -Match 'e\.status === 403'
        $script:access | Should -Match 'scopeNoPerm'
    }
}

Describe 'SCOPE-ADD-1: it finds the roles rather than guessing them' {

    It 'names the custom roles by ID, not by matching their names' {
        # ROLES-1 part 2. This page used to list custom roles at the scope
        # being granted and take the first whose name began 'VMF Assessment'.
        # That also finds roles inherited from a management group above, and
        # roles ANOTHER install of this tool made, and there is no defined
        # order to choose between them - so it could grant the wrong
        # definition, with different permissions, and say nothing.
        #
        # The ids are written into dashboard.config.json by the publish, read
        # from the subscription the roles are defined in. Microsoft's own
        # advice is to use the id: a role can be renamed and its id does not
        # move.
        $script:access | Should -Match 'cfg\.migrateRoleId'
        $script:access | Should -Match 'cfg\.assessRoleId'
        $script:access | Should -Not -Match "find\('VMF Assessment'\)"
        $script:access | Should -Not -Match 'function vmfRolesAt'
    }

    It 'covers the scope before it grants there, and asks before changing the role' {
        # A role can only be granted where its own list reaches. When it
        # already does - the ordinary case - nothing about the role changes.
        $script:access | Should -Match 'async function scopeIsCovered'
        $script:access | Should -Match 'function widenScopes'
        # Widening changes where these roles may be used EVERYWHERE, so it is
        # asked - on the button, never in a browser box (POPUP-1).
        $script:access | Should -Match 'VmfHelp\.confirmInPlace\(btn, \{'
        $script:access | Should -Match 'scopeWidenAsk'
    }

    It 'and when Azure refuses the widening, it names the permission AND the scopes' {
        # The account needs roleDefinitions/write on EVERY place the roles
        # already reach, not only the new one. Reported as a failed grant,
        # which is what happened before, that cannot be acted on.
        $script:access | Should -Match 'scopeWidenDenied'
        $ux = [regex]::Match($script:access, "scopeWidenDenied: '([^']*)'").Groups[1].Value
        $ux | Should -Match 'roleDefinitions/write'
        $ux | Should -Match 'EVERY'
        $ux | Should -Match '\{scopes\}'
    }

    It 'says plainly when the roles are not there, rather than inventing them' {
        # Creating a role definition from here would produce one whose name
        # does not match what the template later generates - so the next
        # template deploy would make a SECOND definition. Better to say what
        # is missing.
        $script:access | Should -Match 'scopeNoRole'
    }

    It 'grants migration OR assessment, never both - migration already contains it' {
        $script:access | Should -Match "mode === 'migrate' \? \(cfg\.migrateRoleId \|\| ''\) : \(cfg\.assessRoleId \|\| ''\)"
    }

    It 'sends principalType ServicePrincipal, because the grantee is an identity' {
        # Omitting it makes the assignment fail intermittently while Entra
        # replication catches up with a freshly created identity.
        $script:access | Should -Match "principalType: 'ServicePrincipal'"
    }
}

Describe 'SCOPE-ADD-1: the page knows which identity to grant to' {

    It 'the deploy publishes the engine principal into the page config' {
        $script:deploy | Should -Match 'enginePrincipalId'
        $script:deploy | Should -Match 'vmf-engine-mi-'
    }

    It 'and reads it by filtering in PowerShell, not with a JMESPath filter' {
        # CLAUDE.md: the az CMD shim eats a filter's brackets and returns an
        # error string that a script then treats as a value. That cost nine
        # orphaned disks on a teardown that reported success seven times.
        $block = [regex]::Match($script:deploy, '(?s)\$engineMi = .*?Select-Object -First 1').Value
        $block | Should -Match 'ConvertFrom-Json'
        $block | Should -Not -Match '--query'
    }

    It 'says so when there is no engine identity, rather than rendering a dead control' {
        $script:deploy | Should -Match 'will not be able to grant it access'
    }

    It 'names the identity EXACTLY, never by prefix' {
        # A prefix match found two during the suffix reconciliation and the page
        # was published naming the wrong one - so the access console would have
        # granted a customer's subscription to an identity nothing runs as.
        $script:deploy | Should -Match '\$engineMiName = "vmf-engine-mi-'
        $script:deploy | Should -Match '\$_\.name -eq \$engineMiName'
        $script:deploy | Should -Not -Match "name -like 'vmf-engine-mi\*'"
    }

    It 'the sample config carries the field, so a hand-built config is not silently short' {
        $sample = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'dashboard.sample.config.json') -Raw |
            ConvertFrom-Json
        $sample.PSObject.Properties.Name | Should -Contain 'enginePrincipalId'
    }
}

Describe 'ROLES-UX-3: the roles step cannot be read as "you already have access"' {
    # A reader of an install log on a work subscription believed the
    # product already had access to it. Two lines said so, in effect:
    #
    #   the roles already reach every scope asked for (1 scope(s))
    #   They can be granted at: /subscriptions/<subscription id>
    #
    # (the id is written as a placeholder here on purpose - SUBID-1 refuses a
    # live one in this repository, and caught this line when it was pasted in
    # from the log verbatim)
    #
    # Both describe where the roles MAY be given out - a property of the role
    # DEFINITION. Neither says anything about who holds one. "Reach" reads as
    # "the product can reach those machines", and "can be granted at" followed
    # by a subscription id reads as a grant that has happened.
    #
    # The step already said "This step gives nobody access to your machines",
    # three lines higher, and was believed less than the id printed below it.
    #
    # ROLES-UX-1 fixed this same misreading on this same step in September. It
    # was fixed one line at a time and these two survived.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        # COMMENT-TRAP-1: both files now quote the old wording in a comment
        # explaining why it went. Only code is read.
        $script:preCode = Get-VmfCodeOnly -Path (Join-Path $script:root 'infra' 'hooks' 'preprovision.ps1')
        $script:scopeCode = Get-VmfCodeOnly -Path (Join-Path $script:root 'infra' 'Resolve-VmfRoleScopes.ps1')
        $script:preRaw = Get-Content (Join-Path $script:root 'infra' 'hooks' 'preprovision.ps1') -Raw
    }

    It 'the comment reader is dropping comments, or nothing below proves anything' {
        $script:preRaw | Should -Match 'They can be granted at'
        $script:preCode | Should -Not -Match 'They can be granted at'
    }

    It 'no line printed to an operator says the roles REACH anywhere' {
        # A role definition does not reach a machine. A person holding it does.
        $said = foreach ($code in @($script:preCode, $script:scopeCode)) {
            foreach ($line in ($code -split "`n")) {
                if ($line -match 'Write-Host' -and $line -match '(?i)roles already reach') { $line.Trim() }
            }
        }
        @($said) | Should -BeNullOrEmpty
    }

    It 'the scope list is introduced by a sentence saying nobody holds one' {
        # ORDER IS THE FIX. The sentence has to be met BEFORE the subscription
        # id, by somebody reading downwards.
        $nobody = $script:preCode.IndexOf('Nobody holds either role yet')
        $list = $script:preCode.IndexOf('These are the places you can give them out')
        $nobody | Should -BeGreaterThan 0
        $list | Should -BeGreaterThan 0
        $list | Should -BeGreaterThan $nobody
    }

    It 'and the step still says the install grants nobody anything' {
        # ROLES-UX-1 put this here. It stays; the new line supports it rather
        # than replacing it.
        $script:preCode | Should -Match 'This step gives nobody access to your machines'
    }

    It 'the scope list is still PRINTED, or this is fixed by saying less' {
        # A person does need to know where they can grant. Deleting the line
        # would pass every check above.
        $script:preCode | Should -Match '\$roleScopes -join'
    }
}
