#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PROJ-DEL-1 - a way out, from the app.
#
# Assessments and projects had no delete button. The app needs a way to
# clear them out.
#
# A store that fills with things nobody can remove is a store people stop
# trusting, and "it might matter" is not a reason to leave no way out - the
# same argument that produced Remove-VmfRun.
#
# WHAT MAY BE DELETED, AND WHAT MAY NOT. An assessment is a record of a scan:
# deleting it loses minutes, so the app may. A project is a NAME: deleting it
# is free while it is empty, and while it holds work it is a series of separate
# decisions, each with its own question about safety copies. Rolling those into
# one button labelled "delete project" is how somebody loses a migration record
# that still knows how to put a machine back. So the engine refuses, and names
# what it holds.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:NewStore {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-store-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $root
    }
}
AfterAll { Remove-Item 'function:\NewStore' -ErrorAction SilentlyContinue }

Describe 'PROJ-DEL-1: removing a project' {
    BeforeEach { $script:store = NewStore }
    AfterEach { if ($script:store -and (Test-Path $script:store)) { Remove-Item $script:store -Recurse -Force } }

    It 'removes an empty project' {
        New-VmfProject -StorePath $script:store -ProjectId 'gone-soon' -Name 'Gone soon' `
            -OnBehalfOf @{ Identity = 'sam@example.com'; TenantId = 't1' } | Out-Null
        (Get-VmfProject -StorePath $script:store).ProjectId | Should -Contain 'gone-soon'

        $r = Remove-VmfProject -StorePath $script:store -ProjectId 'gone-soon' -Reason 'test' `
            -RemovedBy 'sam@example.com' -Confirm:$false
        $r.ProjectId | Should -Be 'gone-soon'
        @(Get-VmfProject -StorePath $script:store) | Should -BeNullOrEmpty
        Test-Path (Join-Path $script:store 'gone-soon') | Should -BeFalse
    }

    It 'REFUSES one that still holds work, and names what it holds' {
        New-VmfProject -StorePath $script:store -ProjectId 'busy-estate' -Name 'Busy' `
            -OnBehalfOf @{ Identity = 'sam@example.com'; TenantId = 't1' } | Out-Null
        $run = Join-Path (Join-Path $script:store 'busy-estate') 'assessment-2026-09-01'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run } {
            Initialize-VmfRun -RunPath $rp -RunId 'assessment-2026-09-01' -Kind 'assessment' | Out-Null
        }

        { Remove-VmfProject -StorePath $script:store -ProjectId 'busy-estate' -Reason 'test' -Confirm:$false } |
            Should -Throw '*still holds*assessment-2026-09-01*'

        # And it is STILL THERE. A refusal that half-deletes is worse than one
        # that deletes.
        (Get-VmfProject -StorePath $script:store).ProjectId | Should -Contain 'busy-estate'
        Test-Path $run | Should -BeTrue
    }

    It 'refuses a project that does not exist rather than reporting success' {
        { Remove-VmfProject -StorePath $script:store -ProjectId 'never-existed' -Reason 'test' -Confirm:$false } |
            Should -Throw '*no project called*'
    }

    It 'is case-sensitive, like the id that created it' {
        # A blob prefix is case-sensitive, so 'Estate' and 'estate' are two
        # different places. ValidatePattern ignores case by default, which is
        # how New-VmfProject once accepted 'UPPER'.
        { Remove-VmfProject -StorePath $script:store -ProjectId 'UPPER' -Reason 'test' -Confirm:$false } |
            Should -Throw
    }

    It 'records who asked and why' {
        New-VmfProject -StorePath $script:store -ProjectId 'audit-me' -Name 'Audit' `
            -OnBehalfOf @{ Identity = 'sam@example.com'; TenantId = 't1' } | Out-Null
        $r = Remove-VmfProject -StorePath $script:store -ProjectId 'audit-me' -Reason 'finished with it' `
            -RemovedBy 'sam@example.com' -Confirm:$false
        $r.RemovedBy | Should -Be 'sam@example.com'
        $r.Reason | Should -Be 'finished with it'
    }

    It 'supports -WhatIf - and changes nothing when asked not to' {
        New-VmfProject -StorePath $script:store -ProjectId 'keep-me' -Name 'Keep' `
            -OnBehalfOf @{ Identity = 'sam@example.com'; TenantId = 't1' } | Out-Null
        Remove-VmfProject -StorePath $script:store -ProjectId 'keep-me' -Reason 'test' `
            -RemovedBy 'sam@example.com' -WhatIf
        (Get-VmfProject -StorePath $script:store).ProjectId | Should -Contain 'keep-me'
    }
}

Describe 'PROJ-DEL-1: the app can reach both deletions' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:dash   = Join-Path $script:repoRoot 'src' 'dashboard'
        $script:facade = Join-Path $script:repoRoot 'src' 'facade'
    }

    It 'the projects page offers it, and only on an EMPTY project' {
        $page = (Get-VmfPageSource -Path (Join-Path $script:dash 'projects.html'))
        # PAGE-SCALE-PROJECTS-1: the row's buttons are the shared list's
        # (help.js listAction); the page gives the Delete action and listens
        # for its click by data-action.
        $page | Should -Match "action: 'delete'"
        $page | Should -Match 'button\[data-action="delete"\]'
        $page | Should -Match 'projects/\$\{encodeURIComponent\(id\)\}/delete'
        # A button whose only purpose is to explain why it will not work is
        # worse than the explanation on its own.
        $page | Should -Match '\(p\.assessments \+ p\.migrations\) === 0'
    }

    It 'the assessments page offers it, in the row where a person is looking' {
        $page = (Get-VmfPageSource -Path (Join-Path $script:dash 'assessments.html'))
        $page | Should -Match 'discardAssessment'
        $page | Should -Match 'runs/\$\{VmfHelp\.VmfRun\.routeSegment\(id\)\}/discard'
        # The delete buttons still did not show on projects or assessments.
        # It was in the panel, behind a chevron and behind an early
        # return that skipped it when the scan found nothing.
        # PAGE-SCALE-ASSESSMENTS-1: the row is the shared list's; the page
        # gives every row a Delete action and listens for its click.
        $page | Should -Match "actions: \[nextAction\(r\), deleteAction\(r\)\]"
        $page | Should -Match "const action = \{ text: UX\.del, action: 'delete', value: r\.id \};"
        $page | Should -Match 'button\[data-action="delete"\]'
    }

    It 'and it refuses when a migration was planned from the assessment' {
        # That migration records where it came from. An assessment deleted
        # underneath it leaves a record pointing at nothing. The control is
        # still DRAWN - disabled, saying why - because a control that vanishes
        # is a control nobody knows exists.
        #
        # PROJ-EMPTY-1: this used to require the reason in a `title`, which is
        # the defect that was reported - a hover has no keyboard, no touch and
        # no screen reader, so the button said nothing to the user at all. The reason
        # is a visible line on the row now, and the check follows it there.
        # PAGE-SCALE-ASSESSMENTS-1: the reason is the shared list's note under
        # the disabled button (tests/js/page-scale-assessments.test.js runs it).
        $page = (Get-VmfPageSource -Path (Join-Path $script:dash 'assessments.html'))
        $page | Should -Match 'if \(!planned\.length\) \{ return action; \}'
        $page | Should -Match 'return Object\.assign\(action, \{ disabled: true,\s*note:'
    }

    It 'and the page SHOWS the result - reading is not drawing' {
        # A delete of a test project looked stuck.
        #
        # It was not stuck. The project was already gone from the store; the
        # handler called load() and never render(), so the row stayed on screen
        # with its button reading "Deleting..." for ever. A delete that works
        # and says nothing is indistinguishable from one that hung - and the
        # person's next move is to press it again.
        #
        # Every state-changing handler must leave the page showing the new
        # truth, not just holding it in a variable.
        # A WINDOW after the handler starts, not a brace-matching regex - what
        # matters is what the handler does once the delete returns.
        $projects = (Get-VmfPageSource -Path (Join-Path $script:dash 'projects.html'))
        $i = $projects.IndexOf('async function deleteProject')
        $i | Should -BeGreaterThan -1
        $body = $projects.Substring($i, 900)
        $body | Should -Match '(?m)^\s+await load\(\);'
        # The CALL, on its own line - not the word, which also appears in the
        # comment above it. A test that a comment can satisfy tests nothing.
        $body | Should -Match '(?m)^\s+render\(\);\s*$' -Because 'the row must go when the project does'

        $assess = (Get-VmfPageSource -Path (Join-Path $script:dash 'assessments.html'))
        $j = $assess.IndexOf('async function discardAssessment')
        $j | Should -BeGreaterThan -1
        $assess.Substring($j, 1200) | Should -Match '(?m)^\s+renderTable\(\);' -Because 'the same rule, on the same day, for the same reason'
    }

    It 'the endpoint exists and is a thin wrapper' {
        $fn = Join-Path $script:facade 'app' 'DeleteProject'
        Test-Path (Join-Path $fn 'function.json') | Should -BeTrue
        (Get-Content (Join-Path $fn 'function.json') -Raw) | Should -Match 'projects/\{projectId\}/delete'
        $run = Get-Content (Join-Path $fn 'run.ps1') -Raw
        $run | Should -Match 'Invoke-VmfFacadeDeleteProject'
        # The refusal must NOT be restated in the endpoint - it belongs where
        # the API path cannot route around it.
        $run | Should -Not -Match 'still holds'
    }

    It 'the facade gates it on the operator role' {
        $core = Get-Content (Join-Path $script:facade 'FacadeCore' 'FacadeCore.psm1') -Raw
        $core | Should -Match 'function Invoke-VmfFacadeDeleteProject'
        $m = [regex]::Match($core, '(?s)function Invoke-VmfFacadeDeleteProject.*?Assert-VmfFacadeRole[^\r\n]*')
        $m.Success | Should -BeTrue -Because 'deleting is a change, and every change is gated'
        $m.Value | Should -Match 'Vmf\.Operator'
    }

    It 'the discard route survives a project id' {
        # PROJECT-1: ids are `project/run` and a slash does not survive a route,
        # so the project travels in the body - the same shape approve uses.
        $run = Get-Content (Join-Path $script:facade 'app' 'PostDiscardRun' 'run.ps1') -Raw
        $run | Should -Match '\$body\.project'
        $run | Should -Match "a-z0-9" -Because 'the project id is validated before it becomes a path'
    }
}
