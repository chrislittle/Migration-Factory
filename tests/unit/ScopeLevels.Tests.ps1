#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PERM-2 - the Admin page grants at the level the customer asked for.
#
# The 'where this tool may work' part listed only subscriptions, not a
# resource group or a management group. And for a management group scope, a
# clear message shows if the user does not have rights at that level, which
# is usually a higher level.
#
# A subscription was the only choice on offer, so a customer who wanted the
# tool in ONE resource group had to grant it the whole subscription - the exact
# opposite of what this page exists to do. The three levels Azure has are the
# three levels this page offers, and the SMALLEST is the default.
#
# The three answers about management groups are all ordinary, none of them an
# error: the directory has none, the account cannot read them, or it can read
# them and still cannot grant there. Each needs a sentence that says what to do
# instead, because granting at a subscription really is a working alternative.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:access   = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.html'))
}

Describe 'PERM-2: all three levels' {

    It 'offers resource group, subscription and management group' {
        foreach ($v in 'rg', 'sub', 'mg') {
            $script:access | Should -Match "name=`"scope-level`" value=`"\`$\{v\}`"|\['$v'," `
                -Because "the page must offer the $v level"
        }
        $script:access | Should -Match 'scopeLevelRg'
        $script:access | Should -Match 'scopeLevelSub'
        $script:access | Should -Match 'scopeLevelMg'
    }

    It 'and the SMALLEST is the default' {
        # Least privilege has to be the path of least resistance, or it is a
        # preference rather than a default.
        $m = [regex]::Match($script:access, "\[\['(\w+)', UX\.scopeLevel")
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -Be 'rg' -Because 'a resource group is the smallest scope that can do the work'
        # And the fallback when nothing is checked agrees with it.
        $script:access | Should -Match "scope-level`"\]:checked'\)\?\.value \?\? 'rg'"
    }

    It 'builds a real Azure scope for each level' {
        # These strings are what the role assignment is written against. A
        # wrong shape here grants in the wrong place, which is the one mistake
        # this page must not make.
        $script:access | Should -Match '/providers/Microsoft\.Management/managementGroups/\$\{'
        $script:access | Should -Match '/subscriptions/\$\{subId\}/resourceGroups/\$\{'
        $script:access | Should -Match "\(subId \? ``/subscriptions/\`$\{subId\}`` : ''\)"
    }

    It 'refuses to grant when the chosen thing is not picked' {
        # An empty select must not become `/subscriptions//resourceGroups/`.
        $script:access | Should -Match "if \(!scope\) return;"
    }

    It 'reads the resource groups of the chosen subscription, not of all of them' {
        $script:access | Should -Match 'resourcegroups\?api-version='
        $script:access | Should -Match "'#scope-pick'\)\.addEventListener\('change', loadResourceGroups\)"
    }
}

Describe 'PERM-2: the existing grants are shown at their real level' {

    It 'names the level of each grant rather than calling everything a subscription' {
        $script:access | Should -Match 'function describeScope'
        $script:access | Should -Match 'scopeLevelNameRg'
        $script:access | Should -Match 'scopeLevelNameMg'
        $script:access | Should -Match 'scopeLevelNameSub'
    }

    It 'reads the level from the assignment scope, which is where the truth is' {
        $script:access | Should -Match 'resourceGroups\\\/\(\[\^/\]\+\)'
        $script:access | Should -Match 'managementGroups\\\/\(\[\^/\]\+\)'
        $script:access | Should -Match 'a\.properties\.scope'
    }
}

Describe 'PERM-2: management groups without the rights' {

    It 'has a message for a directory with no management groups' {
        $script:access | Should -Match 'scopeMgNoneWhy'
        $m = [regex]::Match($script:access, "scopeMgNoneWhy:\s*'([^']*)'")
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -Match '(?i)subscription|resource group' -Because 'it must name what to do instead'
    }

    It 'has a message for an account that cannot read them' {
        $script:access | Should -Match 'scopeMgDeniedWhy'
        $m = [regex]::Match($script:access, "scopeMgDeniedWhy:\s*'([^']*)'")
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -Match '(?i)administrator' -Because 'it must say who can do it'
        $m.Groups[1].Value | Should -Match '(?i)subscription|resource group' -Because 'and what to do meanwhile'
    }

    It 'and the same answer when the GRANT itself is refused' {
        # Listing and granting are different rights. An account can read the
        # management groups and still get a 403 on the assignment.
        $script:access | Should -Match "level === 'mg' \? UX\.scopeMgDeniedWhy : UX\.scopeNoPerm"
    }

    It 'treats none of it as a crash' {
        # A missing right is an answer. The page must not show a stack of
        # Azure error text where a sentence belongs.
        $m = [regex]::Match($script:access, '(?s)async function loadManagementGroups.*?\n\}')
        $m.Success | Should -BeTrue
        $m.Value | Should -Match 'catch'
        $m.Value | Should -Not -Match 'fail\(e\)'
    }
}
