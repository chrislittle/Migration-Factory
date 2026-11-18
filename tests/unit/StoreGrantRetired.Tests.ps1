#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STORE-READ-1 part 2 - the second permission is gone, and gone means gone.
#
# STORE-ACCESS-1 built a whole feature to manage a SECOND permission. An app
# role gated actions at the service; Storage Blob Data Reader gated READING the
# migration records, because the dashboard read blob storage directly with the
# viewer's own token. Giving somebody a role and not the Azure right left them
# signed in and looking at a 403, so the Admin page granted both, removed both,
# reported which half failed, and carried a column saying who could read.
#
# The dashboard does not read blob storage any more. The service reads, with
# its own identity. So there is one permission, the Admin page gives all of it,
# and every part of that feature has been removed.
#
# THIS FILE IS THE REMOVAL, TESTED. The standing rule is that a removal
# must actually remove - leaving a config field, a consent scope, a CORS rule or
# a dead button behind is a claim that something still works this way, and the
# next person to read it believes the claim. Each check below names one thing
# that had to go and fails if it comes back.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:access   = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.html'))
    $script:deploy   = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
    $script:sample   = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'dashboard.sample.config.json') -Raw
    $script:identity = Get-Content (Join-Path $script:repoRoot 'infra' 'identity.bicep') -Raw
    $script:platform = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
    $script:consent  = Get-Content (Join-Path $script:repoRoot 'tools' 'Test-VmfConsentReadiness.ps1') -Raw
    # Sentences the product says, not the comments explaining what it used to
    # say. That history is worth keeping, and a whole-file match cannot tell
    # the two apart - which let two checks pass in the change before this one
    # that should not have.
    $script:said = (Get-VmfCodeOnly -Language CStyle -Text $script:access)
}

Describe 'STORE-READ-1: the Admin page grants one permission, and it is the whole permission' {

    It 'the page no longer knows the built-in Storage Blob Data Reader role' {
        # az role definition list --name 'Storage Blob Data Reader'. Nothing
        # here has any use for it.
        $script:access | Should -Not -Match '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
    }

    It 'and no function that granted, removed or reported it survives' {
        foreach ($gone in 'grantStoreRead', 'revokeStoreRead', 'storeReaders',
                          'storeRoleAssignments', 'storeScope', 'STORE_READER') {
            $script:access | Should -Not -Match $gone -Because "$gone managed a permission that no longer exists"
        }
    }

    It 'and no control offers to repair a person who was granted before it existed' {
        # The repair button existed because a grant could be MISSING. Nothing
        # can be missing now: the role is the whole grant, so a person who was
        # given one is finished.
        $script:said | Should -Not -Match 'data-fixstore'
        $script:said | Should -Not -Match 'UX\.store'
    }

    It 'and the table does not carry a column it can no longer answer' {
        $script:access | Should -Not -Match 'th-store'
        # The column count in the empty-state row must follow the columns, or
        # the "nobody yet" message stops spanning the table.
        $headers = ([regex]::Matches($script:access, '<th id="th-[a-z]+"></th>')).Count
        $headers | Should -Be 3
        $script:access | Should -Match 'colspan="3"'
    }

    It 'giving a role reports the role, with no second half to report' {
        # The three places a role is given or taken. Each used to compose its
        # message from two outcomes; each says one thing now.
        $script:said | Should -Match "flash\('#ok', UX\.roleAdded\)"
        $script:said | Should -Match "flash\('#ok', UX\.added\)"
        $script:said | Should -Match "flash\('#ok', UX\.removed\)"
    }

    It 'and the demo answers nothing about storage role assignments' {
        # The demo drove the removed feature too. A sample answer for a call
        # nothing makes is the same dead claim in another form.
        $script:access | Should -Not -Match 'DEMO\.readers'
        $script:access | Should -Not -Match 'atScope'
    }
}

Describe 'STORE-READ-1: nothing outside the page still arranges that permission' {

    It 'the deploy does not grant the operator a data role on the store' {
        # It granted it to whoever ran the deploy, which was the only reason
        # ONE human could read the records at all.
        $script:deploy | Should -Not -Match 'role assignment create.*Storage Blob Data Reader'
        $script:deploy | Should -Not -Match 'az ad signed-in-user show'
    }

    It 'and it does not tell the operator that viewers need one' {
        # The last line the installer prints. It named a permission nobody
        # needs any more, which is the worst place to be wrong.
        $script:deploy | Should -Not -Match 'Viewers need.*Storage Blob Data Reader'
        $script:deploy | Should -Match 'Viewers need: Entra sign-in and a role in the app'
    }

    It 'and the dashboard is not given the store address it cannot use' {
        foreach ($dead in 'storageAccountId =', 'storageAccount =', 'container      =') {
            $script:deploy | Should -Not -Match ([regex]::Escape($dead)) -Because 'the browser has no use for it'
        }
        $script:sample | Should -Not -Match '"storageAccountId"'
        $script:sample | Should -Not -Match '"storageAccount"'
        $script:sample | Should -Not -Match '"container"'
    }

    It 'and the registration no longer asks a person to consent to Azure Storage' {
        # This is the visible win. Signing in used to ask for a storage
        # permission on top of everything else; it does not now.
        $script:identity | Should -Not -Match 'e406a681-f3d4-42a8-90b6-c2b029497af1' -Because 'the Azure Storage application id'
        $script:identity | Should -Not -Match '03e0da56-190b-40ad-a80c-ea378c433f7f' -Because 'its user_impersonation scope'
        # ARM stays. The Admin page still reads scopes as the signed-in person.
        $script:identity | Should -Match '797f4846-ba00-4fd7-ba43-dac1f8f63013'
    }

    It 'and the consent check does not report on a permission the product stopped asking for' {
        # A readiness check that measures the wrong set is worse than none: it
        # can block an install on a permission nothing wants.
        $script:consent | Should -Not -Match 'e406a681-f3d4-42a8-90b6-c2b029497af1'
        $script:consent | Should -Not -Match "Name = 'Azure Storage'"
        $script:consent | Should -Match "Name = 'Azure Service Management'"
    }

    It 'and the store no longer admits a browser at all' {
        # CORS on a storage account is only ever for a browser. Leaving the
        # rules would say one is still expected.
        $script:platform | Should -Not -Match 'corsRules'
        $script:platform | Should -Not -Match 'allowedMethods'
    }
}

Describe 'STORE-READ-1: what replaced it is really there' {
    # A removal test that only checks absences passes just as well when the
    # replacement was never built. These are the two things that have to be
    # true for the removal to be correct rather than merely complete.

    It 'the service holds the data role the people gave up' {
        # The facade's own system-assigned identity, granted on the store in
        # the template. This is the whole reason a person needs no Azure right:
        # somebody reads the records, and it is this.
        $script:platform | Should -Match 'facade\.outputs\.systemAssignedMIPrincipalId'
        $script:platform | Should -Match 'roleDefinitionIdOrName: roleBlobOwner'
    }

    It 'and the dashboard asks for a token for the service, not for storage' {
        $frontDoor = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'index.html'))
        $frontDoor | Should -Match 'access_as_user'
        $frontDoor | Should -Not -Match 'storage\.azure\.com'
    }
}
