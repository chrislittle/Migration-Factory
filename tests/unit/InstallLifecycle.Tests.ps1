#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# THE INSTALL LIFECYCLE, measured 2026-09-08 and 2026-09-09 by running it.
#
# `azd up` was built on 2026-09-05, reviewed, tested and documented. The first
# time anybody ran it end to end it failed in eighteen seconds, and running the
# WHOLE lifecycle - up, down, up again - found seven separate defects. Every
# one of them was invisible to a test that reads source, because every one of
# them only appears against a live subscription.
#
# These tests hold the fixes in place. They cannot re-run the lifecycle, so
# each states the measurement it stands for.
BeforeAll {
    $script:repoRoot  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:main      = Get-Content (Join-Path $script:repoRoot 'infra' 'main.bicep') -Raw
    $script:preprov   = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1') -Raw
    $script:idDeploy  = Get-Content (Join-Path $script:repoRoot 'infra' 'identity-deploy.ps1') -Raw
    $script:cfg       = Get-Content (Join-Path $script:repoRoot 'bicepconfig.json') -Raw | ConvertFrom-Json
    $script:remove    = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'remove.md') -Raw
    $script:stepByStep = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'step-by-step.md') -Raw
}

Describe 'INSTALL-1: azd must reach the hook that sets the values it checks for' {

    It 'apiAppId has a default, because azd validates parameters BEFORE running hooks' {
        # MEASURED: with no default, `azd up` failed in about eighteen seconds
        # having run no hook at all, on a value only the hook can produce.
        # Identical with and without --no-prompt.
        $script:main | Should -Match "param apiAppId string = ''"
    }

    It 'and an empty value is never DEPLOYED - the platform refuses it' {
        # The default exists to get past azd's check, not to ship a service
        # with no sign-in. EVAL-H13 is what makes that safe.
        $platform = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
        $platform | Should -Match 'apiAppId'
        $platform | Should -Match '(?s)EVAL-H13'
    }

    It 'the hook does not tell a person to run the thing that fails' {
        # It said "Run azd up and answer its first questions". Seeing that
        # message means the hook was run BY HAND, because azd runs it itself -
        # so azd up was the thing that just failed.
        $script:preprov | Should -Not -Match 'Run `azd up` and answer its first questions'
        $script:preprov | Should -Match 'azd env get-values'
    }
}

Describe 'INSTALL-1: the Graph extension is GA and not experimental' {

    It 'pins a GA version' {
        $script:cfg.extensions.microsoftGraphV1 | Should -Match ':\d+\.\d+\.\d+$'
        $script:cfg.extensions.microsoftGraphV1 | Should -Not -Match 'preview'
    }

    It 'and carries NO experimental flag, which is what broke the appId read' {
        # The two together fail with "property 'appId' doesn't exist" and cost
        # an evening, because the obvious suspect was the template. It was not.
        # Six measurements, one variable at a time, are in identity.bicep.
        $script:cfg.PSObject.Properties.Name | Should -Not -Contain 'experimentalFeaturesEnabled'
    }
}

Describe 'INSTALL-1: a removed install must not block the next one' {

    # MEASURED: azd down soft-deletes both registrations, Entra holds the NAME
    # for 30 days, and the Graph extension upserts by uniqueName - so the next
    # install collides with the tombstone and fails on a message about appId.
    # Proven both ways: tombstones present fails, tombstones purged succeeds.

    It 'the deploy clears a deleted registration that still holds the unique name it needs' {
        # INSTALL-PURGE-DELETED-1: by the UNIQUE NAME this install creates,
        # never by display name - InstallPurgeDeleted.Tests.ps1 drives it.
        $script:idDeploy | Should -Match 'Clear-VmfDeletedRegistration'
        $resolve = Get-Content (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRegistration.ps1') -Raw
        $resolve | Should -Match 'deletedItems/microsoft\.graph\.application'
    }

    It 'and matches the unique name EXACTLY, because a purge cannot be undone' {
        $resolve = Get-Content (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRegistration.ps1') -Raw
        $resolve | Should -Match '\[string\]\$_\.uniqueName -eq \$uniqueName'
        $resolve | Should -Not -Match '\$_\.(displayName|uniqueName) -like'
    }

    It 'a purge it cannot do STOPS the install and hands over the command' {
        # Purging needs directory rights the installer may not hold. Reaching
        # the deployment anyway means meeting the confusing error instead.
        $resolve = Get-Content (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRegistration.ps1') -Raw
        $resolve | Should -Match 'may not remove it permanently'
        $resolve | Should -Match 'Ask a directory administrator'
        $resolve | Should -Match 'different environment name'
    }

    It 'and the manual says it before a person meets it' {
        $script:remove | Should -Match '(?i)30 days'
        $script:remove | Should -Match '(?i)install again'
    }
}

Describe 'INSTALL-1: a removal cannot poison the next install' {

    # MEASURED 2026-09-09, one property at a time, against a real tombstone:
    #   same uniqueName, same displayName ... Failed
    #   NEW uniqueName,  same displayName ... Succeeded
    #   same uniqueName, NEW displayName .... Failed
    # So uniqueName is what Entra reserves for 30 days, and displayName is free.
    # So a unique name for the app registration avoids the tombstone, as the
    # IaC already does for its resources - and only that half needs to be unique.

    BeforeAll {
        $script:identity = Get-Content (Join-Path $script:repoRoot 'infra' 'identity.bicep') -Raw
        $script:predown  = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'predown.ps1') -Raw
        # TEARDOWN-1: the registration state is cleared where the
        # registrations are removed, which is postdown now.
        $script:postdown = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'postdown.ps1') -Raw
    }

    It 'the key moves the uniqueName and leaves the displayName alone' {
        # The name in the portal is what a person recognises. Changing it to
        # dodge a tombstone would trade one problem for a worse one.
        $script:identity | Should -Match "var apiUniqueName = empty\(registrationKey\)"
        $script:identity | Should -Match 'uniqueName: apiUniqueName'
        $script:identity | Should -Match 'uniqueName: dashboardUniqueName'
        $script:identity | Should -Match 'displayName: apiDisplayName'
        $script:identity | Should -Match 'displayName: dashboardDisplayName'
    }

    It 'the install never records an EMPTY key, whose uniqueName anybody can make first' {
        # INSTALL-ADOPT-OWNER-1: the empty key used to adopt any registration
        # with the display name. With no recorded key, a registration with the
        # name now stops the install (InstallAdoptOwner.Tests.ps1 drives it).
        $script:preprov | Should -Not -Match 'registrations already exist; their names are kept as they are'
        $script:preprov | Should -Not -Match "Set-AzdValue -Name 'VMF_REGISTRATION_KEY' -Value ''"
    }

    It 'a key is generated ONLY when there is no registration to preserve' {
        $script:preprov | Should -Match 'Resolve-VmfRegistrationKey -RecordedKey'
        $script:preprov | Should -Match 'fresh install: registrations get the key'
    }

    It 'and a removal clears it, so the next install cannot collide' {
        $script:postdown | Should -Match "Set-AzdValue -Name 'VMF_REGISTRATION_KEY' -Value ''"
        $script:predown | Should -Not -Match 'VMF_REGISTRATION_KEY' -Because 'it is cleared where the registrations go'
    }

    It 'the purge survives as the FALLBACK, for registrations deleted by hand' {
        # The key stops azd down creating the problem. It does not help when
        # somebody deletes the registrations in the portal, and then the
        # recorded key still points at names that are tombstoned. That is the
        # ONE case left, so the purge takes only that unique name.
        $script:idDeploy | Should -Match 'Clear-VmfDeletedRegistration'
    }
}

Describe 'INSTALL-1: an install with no console takes the default' {

    # This Describe used to hold -Consequential: the update model REFUSED its
    # default with no console, because taking 'person' disowned a pipeline.
    # MEASURED then: azd down cleared the recorded decisions, a rebuild took
    # 'person', and the pipeline lost all eight grants. PIPELINE-LATER-1
    # (2026-11-02) removed the update model, so no choice left has
    # that cost, and the switch went with its one caller.

    It 'the hosting plan takes its default, because it is free to change' {
        $plan = [regex]::Match($script:preprov, "(?s)Read-VmfChoice -Name 'VMF_HOSTING_PLAN'.*?Options").Value
        $plan | Should -Not -BeNullOrEmpty
        $hooks = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'AzdHooks.ps1') -Raw
        $hooks | Should -Match 'no console; the default is taken'
    }
}
Describe 'INSTALL-1: the times the manual quotes are the times it takes' {

    It 'the removal says about 35 minutes, not 10 to 15' {
        # MEASURED: 34 minutes 6 seconds. The Container Apps environment with
        # workload profiles is nearly all of it, in both directions.
        $script:remove | Should -Match '(?i)about 35 minutes'
        $script:remove | Should -Not -Match '(?i)This takes 10 to 15 minutes'
    }

    It 'and the install owns up to the slow part rather than looking stuck' {
        # MEASURED: 17 minutes 12 seconds the first time, 11 minutes 17 the
        # second. A person who thinks it has hung may kill it - and killing a
        # REMOVAL is worse, because the registrations go first.
        $script:stepByStep | Should -Match '(?i)Container Apps environment'
        $script:remove | Should -Match '(?i)takes most of this time\. Let the command run\.'
    }
}

Describe 'DRILL-C: the whole cycle, run on 2026-09-09' {

    # azd down, then azd up, on a live subscription. What it proved, and the
    # one thing it found.
    BeforeAll {
        $script:ifItFails = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'if-it-fails.md') -Raw
        $script:choices   = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'choices.md') -Raw
        $script:removeDoc = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'remove.md') -Raw
    }

    It 'the removal time is measured twice and agrees' {
        # 34 minutes 6 seconds, then 34 minutes 16 seconds.
        $script:removeDoc | Should -Match '(?i)about 35 minutes'
    }

    It 'the stack error is explained again, because it CAN still happen' {
        # THIS TEST ASSERTED THE OPPOSITE UNTIL 2026-09-14, AND IT WAS WRONG.
        #
        # NO-STACKS-1 deleted the section explaining `A referenced resource was
        # not found` and pinned the deletion here, reasoning: *"NO-STACKS-1
        # removed the object the failed read was against... It cannot happen
        # now."*
        #
        # It can. It happened on a corporate subscription on 2026-09-14:
        #
        #     ResourceNotFound: The resource 'azd-stack-contoso-demo' was not found.
        #
        # azd's `alpha.deployment.stacks` setting is MACHINE-WIDE, and it is
        # what enables stack mode - not the block in azure.yaml, which is only
        # a stack's options. preprovision.ps1 has always known this and checked
        # for it. So the page and the test disagreed with the hook standing
        # three files away, and the page lost.
        #
        # The lesson is not about stacks. Deleting a recovery note because the
        # code changed needs the CONDITION checked, not the intent read.
        # ANCHORED TO THE HEADING, not to the phrase. The phrase also sits in
        # the fenced example inside the section, so `-Match` on its own passed
        # with the section deleted - found by mutation testing.
        # MANUAL-REVIEW-1: the install now STOPS on the setting before it
        # creates anything (preprovision.ps1 throws), so the ResourceNotFound
        # that named the stack cannot reach a 1.0 install. The page explains
        # the stop, under its own heading, with the one command that clears it.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $pre = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1')
        $pre | Should -Match 'alpha\.deployment\.stacks'
        $pre | Should -Match "throw 'Deployment-stack mode is on"
        $script:ifItFails | Should -Match '(?m)^##\s.*deployment-stack mode is on'
        $script:ifItFails | Should -Not -Match '(?m)^##\s.*referenced resource was not found' -Because 'the install stops before that error can happen'
    }

    It 'and it names the cause and the one command that clears it' {
        # The old note said "type azd up again", which worked when the product
        # made stacks on purpose. It does not now: the setting is still on, so
        # the next attempt fails the same way.
        $script:ifItFails | Should -Match 'alpha\.deployment\.stacks off'
        $script:ifItFails | Should -Match '(?i)deployment-stack mode'
    }

    It 'and the recovery for an orphaned deny assignment goes with it' {
        # Five steps, needed because a deny assignment can only be removed by
        # the stack that made it. Nothing here makes one now.
        $script:ifItFails | Should -Not -Match '(?i)deny assignment'
        $script:ifItFails | Should -Not -Match 'az stack sub'
    }

    It 'but the check that a removal really removed survives' {
        # TEARDOWN-1's rule is not about stacks. A removal that reports success
        # is not a removal that happened, and the answer is to look.
        $script:ifItFails | Should -Match '(?i)the removal said it worked and everything is still there'
        $script:ifItFails | Should -Match 'az group show'
        $script:removeDoc | Should -Match 'ResourceGroupNotFound'
    }

    It 'the removal page says the next install may need two attempts' {
        $script:removeDoc | Should -Match '(?i)If you install again'
        $script:removeDoc | Should -Match 'if-it-fails\.md'
    }

    It 'and that a removal clears the two choices' {
        # MEASURED: after azd down, the recorded answers were gone. There were
        # three until PIPELINE-LATER-1 removed the update question.
        $script:removeDoc | Should -Match '(?i)clears the two choices'
    }

    It 'the alpha disclosure is gone, because the dependency is' {
        # It named ONE measured effect - `A referenced resource was not found`
        # on a rebuild - rather than a general fear, which was the right shape
        # while this product used deployment stacks. NO-STACKS-1 removed the
        # dependency, so that disclosure describes a risk the install no longer
        # takes, and would send a reader looking for a warning azd stops
        # printing.
        $script:choices | Should -Not -Match '(?i)alpha feature of the Azure Developer CLI'
        $script:choices | Should -Not -Match 'A referenced resource was not found'
        # What replaced it says what a reader now needs instead: nothing here
        # is protected from deletion, so take the reports out first.
        $script:choices | Should -Match '(?i)One resource group holds the platform'
        $script:choices | Should -Match '(?i)does not lock those resources'
    }
}

Describe 'CONSENT-1: the one directory action the install cannot do for you' {

    # Found 2026-09-09: the first sign-in needs user or admin consent to the
    # app, the manual did not say so, and some enterprises block user consent
    # through Entra ID policies.
    #
    # It is stronger than that, and READ FROM GRAPH rather than remembered:
    # three of the dashboard's delegated scopes are type 'Admin', so consent is
    # reserved to a directory administrator in EVERY tenant, not only where a
    # policy blocks users.
    #
    #   AppRoleAssignment.ReadWrite.All   ADMIN
    #   Application.Read.All              ADMIN
    #   Group.Read.All                    ADMIN
    #   AuditLog.Read.All                 ADMIN   (only with the sign-in read)
    #   User.ReadBasic.All                a user may consent
    #
    # Nothing granted it and nothing mentioned it. A test install never met
    # it, because its user was an administrator and consented in passing.

    BeforeAll {
        $script:identity   = Get-Content (Join-Path $script:repoRoot 'infra' 'identity.bicep') -Raw
        $script:postprov   = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1') -Raw
        # CONSENT-DONE-CHECK-1: the closing words moved to Get-VmfConsentClosing,
        # which postprovision prints, so they are only said when consent is not given.
        $script:closing    = Get-Content (Join-Path $script:repoRoot 'infra' 'Resolve-VmfInstallerRights.ps1') -Raw
        $script:preprov2   = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1') -Raw
        $script:beforeYou  = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'install' 'before-you-install.md') -Raw
        $script:signIn     = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'use' 'sign-in.md') -Raw
    }

    It 'the registration still asks for the scopes that need an administrator' {
        # If these ever go, this whole item goes with them - so read it from
        # the template rather than trusting the tests below to still matter.
        $script:identity | Should -Match '84bccea3-f856-4a8a-967b-dbe0a3d53a64'   # AppRoleAssignment.ReadWrite.All
        $script:identity | Should -Match 'c79f8feb-a9db-4090-85f9-90d820caa0eb'   # Application.Read.All
        $script:identity | Should -Match '5f8c59db-677d-491f-a6b8-5f174b11ec1d'   # Group.Read.All
    }

    It 'the install RECORDS the dashboard application id, which it always had and never kept' {
        $script:preprov2 | Should -Match "Set-AzdValue -Name 'VMF_DASHBOARD_APP_ID'"
    }

    It 'and the install says the action is outstanding, with the command' {
        # Until it is done NOBODY can sign in, and Microsoft's refusal does not
        # say why. Silence here is the whole defect.
        # CORRECTED 2026-09-10. This asserted 'nobody can sign in until it is
        # done', which is FALSE and shipped. Every scope the ordinary pages ask
        # for is user-consentable - storage and ARM user_impersonation, and our
        # own access_as_user, declared type 'User'. Only access.html asks for
        # Graph, and only when it needs it. The real limit is narrower: until
        # somebody approves, the installer is the only person who can sign in,
        # because the Admin page is where a role is given.
        $script:closing | Should -Match '(?i)before you can give anyone else access'
        $script:closing | Should -Match '(?i)You can use the product now'
        $script:postprov | Should -Match 'Get-VmfConsentClosing'
        # INSTALL-CONSENT-PUSH-1: the way to do it is a link or Microsoft's
        # request workflow, approved in the browser - never a command for
        # somebody else to run (rule 12). tests/unit/InstallConsentPush.Tests.ps1
        # runs the hand-off itself.
        $script:closing | Should -Match 'Get-VmfConsentHandoff'
        # Code only: the comment that says why the command went still names it.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $postCode = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1')
        $postCode | Should -Not -Match 'az ad app permission admin-consent'
    }

    It 'it names who can do it, rather than saying "an administrator"' {
        # The names live with the rights reader, the one list of them, and the
        # hand-off prints them from there.
        $rightsFile = Get-Content (Join-Path $script:repoRoot 'infra' 'Resolve-VmfInstallerRights.ps1') -Raw
        $rightsFile | Should -Match "'Global Administrator'"
        $rightsFile | Should -Match "'Cloud Application Administrator'"
        $script:postprov | Should -Match 'Resolve-VmfInstallerRights\.ps1'
    }

    It 'the install does NOT grant it silently' {
        # Approving permissions across a directory is not something an install
        # should do on somebody's behalf without being asked.
        $script:postprov | Should -Not -Match '(?m)^\s*az ad app permission admin-consent'
    }

    It 'the manual asks for it BEFORE the install, not after the failure' {
        $script:beforeYou | Should -Match '(?i)A directory administrator, once - for the Admin page only'
        $script:beforeYou | Should -Match '(?i)No user can approve them, in any directory'
        $script:beforeYou | Should -Match 'AppRoleAssignment\.ReadWrite\.All'
    }

    It 'and the sign-in page explains what the first person meets' {
        # The claim is now about the ADMIN PAGE's permissions, not the app.
        # "No user can approve IT" was the overstatement; "no user can approve
        # THEM" is true of the three Graph scopes access.html asks for.
        $script:signIn | Should -Match '(?i)you can approve this yourself'
        $script:signIn | Should -Match '(?i)No user can approve them, in any directory'
        $script:signIn | Should -Match 'Global Administrator'
    }

    It 'and it does NOT claim the whole product needs an administrator' {
        # The correction, guarded. Every scope the ordinary pages request is
        # user-consentable, so a blanket claim sends a customer to ask their
        # directory team for something they do not need yet.
        $script:signIn   | Should -Not -Match '(?i)every person is refused'
        $script:beforeYou | Should -Not -Match '(?i)Nobody can use the dashboard until it is done'
        $script:postprov | Should -Not -Match '(?i)nobody can sign in until it is done'
        $script:closing | Should -Not -Match '(?i)nobody can sign in until it is done'
    }

    It 'and it does not claim the opposite either: a user can approve it only where the directory allows' {
        # The second overstatement, in the other direction. MEASURED 2026-09-10
        # in a corporate tenant: it assigns
        # ManagePermissionGrantsForSelf.microsoft-user-default-low, which lets a
        # user approve ONLY permissions an administrator marked as low impact -
        # and nothing is marked by default. So "you can approve this yourself"
        # is true in most directories and false in that one. A customer there
        # would have read the manual, tried, been refused, and had no idea why.
        foreach ($text in @($script:signIn, $script:beforeYou, $script:closing)) {
            $text | Should -Match '(?i)in most directories'
            $text | Should -Match '(?i)(stricter|low impact)'
        }
        # The claim must never appear unqualified again.
        $script:signIn | Should -Not -Match '(?<!directories )[Yy]ou can approve this yourself'
    }
}
