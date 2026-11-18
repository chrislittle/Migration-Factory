#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PERM-3 - access can be taken away, and a grant on a deleted place says so.
#
# After a test fleet was torn down, its deleted resource group still showed on
# the Admin page.
#
# Two problems in one finding.
#
# The one that was seen: a grant on a resource group that no longer exists
# does nothing, and it sits in "Where this tool may work" reading as access the
# tool still has. That is a picture of reality that has quietly stopped being
# true.
#
# The one behind it: this page could only ever GIVE access. The way to take it
# away was the Azure portal, which makes the page half a control - and means
# its picture drifts from the truth by design, not by accident.
#
# Both are the same shape as the rest of this page: done AS THE SIGNED-IN
# PERSON with their own token, because the app deliberately holds no rights to
# change access (PERM-2).
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:access   = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.html'))
}

Describe 'PERM-3: taking access away' {

    It 'every grant has a Remove' {
        $script:access | Should -Match 'data-revoke='
        $script:access | Should -Match 'async function revokeScope'
    }

    It 'deletes the role assignment by its own id, never one this page builds' {
        # A constructed assignment id either misses or, worse, points at
        # somebody else's assignment. The id comes from the listing.
        $script:access | Should -Match "arm\('DELETE', ``\`$\{assignmentId\}\?api-version="
        $script:access | Should -Match 'id: a\.id'
    }

    It 'asks first - this is not undoable from here' {
        # POPUP-1: asked IN the page by the shared control, and the delete
        # (revokeScopeNow) runs only from its Yes.
        $script:access | Should -Match 'scopeRemoveConfirm'
        $m = [regex]::Match($script:access, '(?s)function revokeScope\(assignmentId, btn, serviceAssignmentId, shared, serviceOnly, losing\) \{.*?VmfHelp\.confirmInPlace\(btn.*?revokeScopeNow')
        $m.Success | Should -BeTrue -Because 'the question must come before the delete'
        # ACCESS-HALF-1: there are TWO deletes now - the product reaches a
        # place through two identities and a removal must remove both. The
        # second one has to sit behind the same question as the first, so it
        # lives inside revokeScopeNow and nowhere else.
        $doing = [regex]::Match($script:access, '(?s)async function revokeScopeNow\(.*?\n\}').Value
        $doing | Should -Match 'serviceAssignmentId'
        @([regex]::Matches($doing, "arm\('DELETE'")).Count |
            Should -Be 2 -Because 'both identities are removed, and both behind the confirmation'
    }

    It 'as the signed-in person, like every other change on this page' {
        # `true` is the interactive flag on arm(): the person's own token, not
        # the app's. The app holds no rights to change access at all.
        $script:access | Should -Match "\?api-version=2022-04-01``, null, true\)"
    }

    It 'treats already-gone as success rather than as an error' {
        $m = [regex]::Match($script:access, '(?s)async function revokeScope.*?\n\}')
        # ACCESS-REMOVE-SHARED-1: an engine assignment already gone is not
        # thrown, so the web service half is still decided after it.
        $m.Value | Should -Match 'status !== 404'
        $m.Value | Should -Match '403'
    }
}

Describe 'PERM-3: a grant on a place that no longer exists' {

    It 'is marked, not silently listed as working access' {
        $script:access | Should -Match 'scopeGone'
        $script:access | Should -Match 'r\.stale'
    }

    It 'and explains what to do about it' {
        $m = [regex]::Match($script:access, "scopeGoneWhy:\s*'([^']*)'")
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -Match '(?i)remove' -Because 'the answer is on the same row'
    }

    It 'only when the resource groups were actually READ' {
        # THE FAILURE TO AVOID: a listing that failed means "cannot tell", and
        # showing that as "no longer exists" would tell somebody their access is
        # dead when it is fine. Unknown must never become an answer - the same
        # rule the assessment engine follows for image support and driver
        # floors.
        $script:access | Should -Match 'liveGroups = null;\s*\}\s*// cannot tell is not the same as gone|cannot tell is not the same as gone'
        $script:access | Should -Match '!!\(rgName && liveGroups && !liveGroups\.has'
    }

    It 'and reads the groups once per subscription, only when something needs it' {
        # One call per subscription that actually holds a resource-group grant,
        # not one per assignment and not one for every subscription.
        # ACCESS-SERVICE-ORPHAN-1: a web service only row is a grant too.
        $script:access | Should -Match 'const needsGroups = assignments\.concat\(serviceOurs\)\.some'
        $script:access | Should -Match 'if \(needsGroups\)'
    }
}
