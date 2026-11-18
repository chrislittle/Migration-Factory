#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# POLICY-DRIFT: watch the Azure built-in POLICY our NVA
# detection is generated from, the way UPST-1 watches scripts and UPST-3
# watches docs.
#
# data/nva-offers.json is generated from Microsoft's MANA NVA policy. A new
# policy version - a vendor added, an offer pattern changed - invalidates that
# data with nothing in our code moving. The workflow reports it in the same
# daily issue as the other two watchers.
BeforeAll {
    # TEMP-LITTER-1: this file made ten loose json files in the temp folder per
    # run and removed none of them - 1,342 of the 4,307 measured there.
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'pol'

    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:tool = Join-Path $script:repoRoot 'tools' 'Test-PolicyDrift.ps1'
    $script:baselinePath = Join-Path $script:repoRoot 'docs' 'upstream-policies.json'
    $script:baseline = Get-Content $script:baselinePath -Raw | ConvertFrom-Json -Depth 8

    function Script:NewBaseline {
        param($Sha = ('a' * 40), $PinnedVersion = '1.3.0', $DefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/fake-guid')
        $doc = @{
            schemaVersion = 1
            repo = 'Azure/azure-policy'
            branch = 'master'
            checkedUtc = '2026-08-28T00:00:00Z'
            policies = @(@{
                name = 'Fake_Policy.json'
                path = 'built-in-policies/policyDefinitions/Compute'
                sha = $Sha
                pinnedVersion = $PinnedVersion
                policyDefinitionId = $DefinitionId
                localDerivatives = @('src/VmMigrationFactory/data/nva-offers.json')
            })
        }
        $tmpFile = Join-Path $script:temp "baseline-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        $doc | ConvertTo-Json -Depth 8 | Set-Content $tmpFile
        $tmpFile
    }
    function Script:Listing {
        param($Items)
        $captured = $Items
        { param($Repo, $Branch, $Folder) $captured }.GetNewClosure()
    }
    function Script:File { param($Name, $Sha) [pscustomobject]@{ name = $Name; path = "x/$Name"; sha = $Sha; type = 'file' } }
    function Script:Content {
        param($Version)
        $captured = (@{ properties = @{ metadata = @{ version = $Version } } } | ConvertTo-Json -Depth 6)
        { param($Repo, $Branch, $Path) $captured }.GetNewClosure()
    }
}

Describe 'POLICY-DRIFT: the real baseline is well-formed' {
    It 'pins the MANA NVA policy at the version the data file was generated from' {
        $p = @($script:baseline.policies) | Where-Object name -eq 'MANAExistingVMNVASupport_Modify.json'
        $p | Should -Not -BeNullOrEmpty
        $p.pinnedVersion | Should -Be '1.4.0'
        $p.sha | Should -Match '^[0-9a-f]{40}$'
        $p.policyDefinitionId | Should -Match 'e87a87f5-e6dd-4919-be21-abb0a4ea4630'
    }

    It 'agrees with the generated data file - the internal-drift invariant, asserted at rest' {
        $nva = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'nva-offers.json') -Raw | ConvertFrom-Json
        $p = @($script:baseline.policies) | Where-Object { $_.policyDefinitionId -eq $nva.source.policyDefinitionId }
        $p.pinnedVersion | Should -Be ([string]$nva.source.version) -Because 'the pin and the generated data must move together'
    }

    It 'says what to regenerate when the policy moves' {
        $p = @($script:baseline.policies)[0]
        @($p.localDerivatives) -join ' ' | Should -Match 'nva-offers'
        @($p.localDerivatives) -join ' ' | Should -Match 'REGENERATE'
    }
}

Describe 'POLICY-DRIFT: drift detection (no network)' {
    It 'reports nothing when the blob matches the pin' {
        $bl = Script:NewBaseline
        $r = & $script:tool -BaselinePath $bl -ListingProvider (Script:Listing @(Script:File 'Fake_Policy.json' ('a' * 40)))
        @($r.Drifted).Count | Should -Be 0
        $r.Checked | Should -Be 1
    }

    It 'a changed blob is drift, and the report NAMES the version change' {
        # "content changed" alone sends someone diffing JSON to learn what one
        # field would have told them.
        $bl = Script:NewBaseline
        $r = & $script:tool -BaselinePath $bl `
            -ListingProvider (Script:Listing @(Script:File 'Fake_Policy.json' ('b' * 40))) `
            -ContentProvider (Script:Content '1.4.0')
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].reason | Should -Match 'pinned version 1\.3\.0'
        $r.Drifted[0].reason | Should -Match '1\.4\.0'
        $r.Drifted[0].localDerivatives -join ' ' | Should -Match 'nva-offers'
    }

    It 'a REMOVED policy is drift - the list our detection is generated from is gone' {
        $bl = Script:NewBaseline
        $r = & $script:tool -BaselinePath $bl -ListingProvider (Script:Listing @())
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].reason | Should -Match 'REMOVED'
    }

    It 'a listing it cannot read FAILS - never "unchanged" on no evidence' {
        $bl = Script:NewBaseline
        $r = & $script:tool -BaselinePath $bl -ListingProvider { throw 'rate limited' }
        @($r.Drifted).Count | Should -Be 1
        $r.Drifted[0].reason | Should -Match 'listing failed'
    }

    It 'the data file and the pin disagreeing is drift TOO - internal, invisible to any fetch' {
        # Someone regenerates the data without re-pinning, or re-pins without
        # regenerating: upstream looks clean both times, and the two local
        # halves quietly describe different policy versions.
        $bl = Script:NewBaseline -PinnedVersion '9.9.9' `
            -DefinitionId '/providers/Microsoft.Authorization/policyDefinitions/e87a87f5-e6dd-4919-be21-abb0a4ea4630'
        $r = & $script:tool -BaselinePath $bl -ListingProvider (Script:Listing @(Script:File 'Fake_Policy.json' ('a' * 40)))
        @($r.Drifted | Where-Object { $_.reason -match 'INTERNAL drift' }).Count | Should -Be 1
    }

    It '-UpdateBaseline re-pins the sha AND carries the new version into the pin' {
        $bl = Script:NewBaseline
        & $script:tool -BaselinePath $bl `
            -ListingProvider (Script:Listing @(Script:File 'Fake_Policy.json' ('c' * 40))) `
            -ContentProvider (Script:Content '2.0.0') -UpdateBaseline | Out-Null
        $rep = Get-Content $bl -Raw | ConvertFrom-Json -Depth 8
        $rep.policies[0].sha | Should -Be ('c' * 40)
        $rep.policies[0].pinnedVersion | Should -Be '2.0.0'
    }
}

# PUBLIC-SYNC-1: this repository's workflows do not ship to the public one.
# There this runs on the public workflow (public/.github), once there is one.
Describe 'POLICY-DRIFT: wired into the daily action, not a tool nobody runs' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'upstream-drift.yml'))) {
    BeforeAll {
        $script:wf = Get-Content (Join-Path $script:repoRoot '.github' 'workflows' 'upstream-drift.yml') -Raw
    }

    It 'the workflow runs it alongside the script and doc checks' {
        $script:wf | Should -Match 'Test-PolicyDrift\.ps1'
        $script:wf | Should -Match "Add-Section 'Built-in policy sources"
    }

    It 'and its count feeds the total that turns the run red and raises the issue' {
        # UPST-4 moved the arithmetic: the three results are combined first,
        # then split by kind, so the policy check still reaches the total but
        # no longer by its own name in that expression.
        $script:wf | Should -Match '\$all = @\(\$scripts\.Drifted\) \+ @\(\$docs\.Drifted\) \+ @\(\$policies\.Drifted\)'
        $script:wf | Should -Match '\$total = \$changedCount \+ \$unreachableCount'
    }
}

# UPST-4. On 2026-09-13 the scheduled run was rate-limited by GitHub, could not
# read a single listing, and opened an issue titled "Microsoft changed
# something we track". Nothing had changed. The rule the drills produced - a
# check that cannot reach its evidence FAILS - was right and is kept; what was
# wrong is reporting the failure to look as a finding.
# PUBLIC-SYNC-1: this repository's workflows do not ship to the public one.
# There this runs on the public workflow (public/.github), once there is one.
Describe 'UPST-4: the drift issue must not claim a change nobody measured' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'upstream-drift.yml'))) {
    BeforeAll {
        $script:wf4 = Get-Content (Join-Path $script:repoRoot '.github' 'workflows' 'upstream-drift.yml') -Raw
    }

    It 'counts what changed separately from what could not be read' {
        # The two counts must come from the SAME set split by kind - one
        # number for both is the false alarm.
        $script:wf4 | Should -Match '\$changedCount = @\(\$all \| Where-Object'
        $script:wf4 | Should -Match '\$unreachableCount = @\(\$all \| Where-Object'
        $script:wf4 | Should -Match "-ne 'unreachable'"
        $script:wf4 | Should -Match "-eq 'unreachable'"
        $script:wf4 | Should -Match 'changed=\$changedCount'
        $script:wf4 | Should -Match 'unreachable=\$unreachableCount'
    }

    It 'titles the issue by what actually happened' {
        $script:wf4 | Should -Match 'Upstream drift: Microsoft changed something we track'
        $script:wf4 | Should -Match 'Upstream drift: the check could not reach Microsoft'
        # The change title must be chosen by the CHANGED count, never by the total.
        $script:wf4 | Should -Match "if \('\$\{\{ steps\.check\.outputs\.changed \}\}' -ne '0'\)"
    }

    It 'still fails the run when nothing could be checked' {
        # The whole point of the original rule. A quiet pass here is the
        # failure mode that made this check exist.
        $script:wf4 | Should -Match "steps\.check\.outputs\.drifted != '0'"
    }

    It 'and says so even when raising the issue failed first' {
        # REPORT-1, measured 2026-09-19: the report step died, so this step was
        # SKIPPED and the run's only error named a missing tool. Nine changed
        # pages never reached the run's error line.
        $script:wf4 | Should -Match "if: always\(\) && steps\.check\.outputs\.drifted != '' && steps\.check\.outputs\.drifted != '0'"
    }

    It 'but stays quiet when the check measured nothing at all' {
        # An empty count is not a drift of zero. If the check itself failed,
        # this must not announce a number nobody counted.
        $script:wf4 | Should -Match "steps\.check\.outputs\.drifted != ''"
    }

    It 'tells the reader an unreachable item was NOT checked, and offers nothing to re-pin' {
        $script:wf4 | Should -Match '\*\*Not checked\*\*'
        $script:wf4 | Should -Match 'neither confirmed unchanged nor found to have changed'
        $script:wf4 | Should -Match 'Nothing to re-pin'
    }

    It 'raises the read limit with the repository token, which is what the 403 was' {
        $script:wf4 | Should -Match 'VMF_DRIFT_TOKEN: \$\{\{ github\.token \}\}'
    }
}

# REPORT-1, 2026-09-19: the report has to be openable. See DocsDrift.Tests.ps1.
Describe 'REPORT-1: every policy drift entry can be opened' {

    It 'a changed policy, a removed one and an unreadable listing all carry their links' {
        $bl = Script:NewBaseline
        $changed = & $script:tool -BaselinePath $bl `
            -ListingProvider (Script:Listing @(Script:File 'Fake_Policy.json' ('b' * 40))) `
            -ContentProvider (Script:Content '1.4.0')
        $removed = & $script:tool -BaselinePath (Script:NewBaseline) -ListingProvider (Script:Listing @())
        $unreadable = & $script:tool -BaselinePath (Script:NewBaseline) -ListingProvider {
            param($Repo, $Branch, $Folder) throw 'rate limited'
        }

        $all = @($changed.Drifted) + @($removed.Drifted) + @($unreadable.Drifted)
        @($all | Where-Object { $_.kind -eq 'changed' }).Count | Should -Be 2
        @($all | Where-Object { $_.kind -eq 'unreachable' }).Count | Should -Be 1
        foreach ($d in $all) {
            $d.url        | Should -Be "https://github.com/Azure/azure-policy/blob/master/$($d.path)"
            $d.changesUrl | Should -Be "https://github.com/Azure/azure-policy/commits/master/$($d.path)"
        }
    }
}

AfterAll {
    # TEMP-LITTER-1. A throw here fails the container, which is the point: a
    # removal nobody checks is how four thousand folders accumulated.
    Remove-VmfTestTemp
}