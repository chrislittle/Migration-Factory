#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STOREPATH-1 - Split-Path -Parent silently corrupts a blob store path.
#
# FOUND BY THE VOLUME DRILL, 2026-09-01, and it had already broken the product.
#
# `Split-Path -Parent` does not throw on 'azblob://a/c/run/file'. It returns
# 'azblob:' followed by BACKSLASH-separated segments, which the store no longer
# recognises as a blob path - and the caller eventually gets "Cannot find drive.
# A drive with the name 'azblob' does not exist." raised somewhere else entirely.
#
# ASSESS-PAGE-1's approval gate derives the assessment's directory that way to
# find approval.json. So from the moment that gate shipped, PLANNING FROM ANY
# ASSESSMENT ON BLOB STORAGE FAILED - approved or not - and blob storage is what
# the hosted engine uses.
#
# EVERY UNIT TEST PASSED THROUGHOUT, because they all use local temp directories.
# That is the actual lesson, and the last Describe here is the fix for it.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
}

Describe 'STOREPATH-1: the parent of a blob path is still a blob path' {
    It 'keeps the azblob:// scheme and its forward slashes' {
        InModuleScope VmMigrationFactory {
            $r = Split-VmfStorePath -Path 'azblob://acct/cont/run/assess/assessment.json'
            $r | Should -Be 'azblob://acct/cont/run/assess'
            $r | Should -Not -Match '\\' -Because 'a backslash is what broke it'
        }
    }

    It 'walks up one level at a time' {
        InModuleScope VmMigrationFactory {
            Split-VmfStorePath -Path 'azblob://acct/cont/run/assess' | Should -Be 'azblob://acct/cont/run'
            Split-VmfStorePath -Path 'azblob://acct/cont/run'        | Should -Be 'azblob://acct/cont'
        }
    }

    It 'stops at account/container rather than inventing a parent above it' {
        # 'azblob://acct' is not a store path. Returning it would hand callers
        # something that looks usable and is not.
        InModuleScope VmMigrationFactory {
            Split-VmfStorePath -Path 'azblob://acct/cont' | Should -Be 'azblob://acct/cont'
        }
    }

    It 'ignores a trailing slash' {
        InModuleScope VmMigrationFactory {
            Split-VmfStorePath -Path 'azblob://acct/cont/run/assess/' | Should -Be 'azblob://acct/cont/run'
        }
    }

    It 'still does the ordinary thing for a local path' {
        InModuleScope VmMigrationFactory {
            $r = Split-VmfStorePath -Path (Join-Path 'C:\tmp\run' 'assessment.json')
            $r | Should -Be 'C:\tmp\run'
        }
    }

    It 'and this is exactly what Split-Path -Parent gets WRONG' {
        # The regression this file exists for, pinned against the real cmdlet so
        # it cannot be argued away.
        $native = Split-Path 'azblob://acct/cont/run/assess/assessment.json' -Parent
        $native | Should -Match '\\' -Because 'the native cmdlet mangles it - that is the bug'
        InModuleScope VmMigrationFactory {
            (Split-VmfStorePath -Path 'azblob://acct/cont/run/assess/assessment.json') |
                Should -Not -Be (Split-Path 'azblob://acct/cont/run/assess/assessment.json' -Parent)
        }
    }
}

Describe 'STOREPATH-1: the gate uses it' {
    It 'New-VmfPlan derives the assessment directory with the store-aware helper' {
        $plan = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfPlan.ps1') -Raw
        $plan | Should -Match 'Split-VmfStorePath -Path \$AssessmentPath'
        $plan | Should -Not -Match 'Split-Path \$AssessmentPath -Parent'
    }
}

Describe 'STOREPATH-1: nothing else may make the same mistake' {
    # THE REAL FIX. A unit suite that only ever uses local paths cannot see this
    # class of bug, so the guard is static: no -Parent on a value that could be a
    # store path, unless it is already inside the file-backend branch.
    It 'no Split-Path -Parent outside the file backend' {
        # SCOPE WIDENED after the drill found the identical bug in
        # tests/lab/_DrillCommon.ps1, which the first version of this guard did
        # not scan. Anything that can hold a store path counts - the engine, the
        # drills that drive it, and the tools that deploy it.
        $roots = @(
            (Join-Path $script:repoRoot 'src' 'VmMigrationFactory')
            (Join-Path $script:repoRoot 'tests' 'lab')
            (Join-Path $script:repoRoot 'tools')
            (Join-Path $script:repoRoot 'docker')
        ) | Where-Object { Test-Path $_ }
        $offenders = @()
        foreach ($f in ($roots | ForEach-Object { Get-ChildItem $_ -Filter '*.ps1' -Recurse })) {
            $text = Get-Content $f.FullName -Raw
            # A file that never touches the store cannot hold a store path, so
            # its Split-Path calls are on genuine filesystem paths. Without this
            # the guard flags tools/Get-VmfV7Sweep.ps1, whose $OutPath is a local
            # evidence file that merely shares the parameter NAME. A guard that
            # cries wolf is a guard somebody switches off.
            if ($text -notmatch 'azblob|Vmf(Store|StateDoc)|Initialize-VmfRun|-RunPath') { continue }
            $lines = Get-Content $f.FullName
            $inBlockComment = $false
            for ($i = 0; $i -lt $lines.Count; $i++) {
                # Comments describe the trap; they are not the trap. Without this
                # the guard flags Split-VmfStorePath's own documentation, which
                # is the funniest possible false positive and still a false one.
                if ($lines[$i] -match '<#') { $inBlockComment = $true }
                $wasComment = $inBlockComment
                if ($lines[$i] -match '#>') { $inBlockComment = $false }
                if ($wasComment -or $lines[$i].TrimStart().StartsWith('#')) { continue }
                if ($lines[$i] -notmatch 'Split-Path' -or $lines[$i] -notmatch '-Parent') { continue }
                # Only STORE paths are at risk. Plenty of Split-Path -Parent
                # calls are on genuine filesystem paths - an evidence file, a
                # script root - and flagging those is noise that gets a guard
                # switched off. These are the parameter names that carry a path
                # which may be azblob://.
                if ($lines[$i] -notmatch '\$(\w*(RunPath|AssessmentPath|OutPath|PlanPath|StorePath|RunRoot)\w*)') { continue }
                # The escape hatches below look at the CODE above the line, with
                # comments stripped. That is not fussiness: the first version
                # searched the raw window, so the comment explaining the azblob
                # trap silently suppressed the check on the very next line - the
                # guard was disarmed by its own documentation, and a mutation
                # test caught it.
                $window = @($lines[[math]::Max(0, $i - 12)..$i] |
                    Where-Object { -not $_.TrimStart().StartsWith('#') } |
                    ForEach-Object { ($_ -split '\s#')[0] }) -join "`n"
                # Inside the file backend, Split-Path is correct and intended.
                if ($window -match "Backend -eq 'file'") { continue }
                # An explicit azblob branch above it is the other correct shape.
                if ($window -match "match\s*'\^azblob|-eq\s*'azblob") { continue }
                $offenders += "$($f.Name):$($i + 1): $($lines[$i].Trim())"
            }
        }
        ($offenders -join "`n") | Should -BeNullOrEmpty -Because 'Split-Path -Parent corrupts azblob:// paths - use Split-VmfStorePath'
    }
}

Describe 'STORE-WHATIF-1: listing the store survives -WhatIf' {
    # Found by the reaper's own -WhatIf test, 2026-09-02.
    #
    # `ForEach-Object` supports ShouldProcess. So inside a cmdlet running under
    # -WhatIf, `Get-ChildItem ... | ForEach-Object Name` DOES NOT RUN and the
    # pipeline yields nothing. Every caller then saw an empty store and
    # reported "nothing to do".
    #
    # That is the most dangerous wrong answer a preview can give: it looks like
    # a clean result, so the person stops looking.
    BeforeAll {
        $script:storeApi = Get-Content (Join-Path ([System.IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot '..' '..'))) 'src' 'VmMigrationFactory' 'Private' 'state' 'StoreApi.ps1') -Raw
    }

    It 'no store listing pipes through ForEach-Object' {
        $script:storeApi | Should -Not -Match 'Get-ChildItem[^
]*\|\s*ForEach-Object'
    }

    It 'and the listings really do return names under -WhatIf' {
        # Proven by RUNNING one inside a cmdlet that is previewing, which is
        # the only way to see this.
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wi-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $root 'child-one') -Force | Out-Null
        try {
            $names = InModuleScope VmMigrationFactory -Parameters @{ r = $root } {
                function Test-WhatIfListing {
                    [CmdletBinding(SupportsShouldProcess)]
                    param([string]$Root)
                    @(Get-VmfStorePrefixes -StorePath $Root)
                }
                Test-WhatIfListing -Root $r -WhatIf
            }
            @($names) | Should -Contain 'child-one' -Because 'a preview must see the same store an apply would'
        }
        finally { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
