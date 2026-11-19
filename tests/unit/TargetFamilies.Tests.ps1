#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# SCOPE-DATA-1: the product must only plan a move onto a platform Microsoft
# lists as a v6/v7 target.
#
# THE DEFECT THESE TESTS HOLD SHUT, measured 2026-09-22:
#   Standard_D2ps_v5  family=D  familyInScope=True  target=Standard_D2ps_v6
# Both sizes are real, so asking the region's catalogue "does the D family
# have a v6 size" answers yes - and both are Ampere ARM, which appears in NO
# row of the migration guide's target-families table.
#
# The enforceable content of that table is its PLATFORM column (Intel and AMD),
# not its middle column: that one says "Examples", and Ddsv6 - this product's
# most common target - is not among them. A literal allowlist of the twelve
# names would refuse the product's own primary path.
#
# Two documented facts, one page each:
#   target families  sizes-v6-v7-migration-overview.md #target-vm-families
#   the letters      vm-naming-conventions: a = AMD, p = ARM, neither = Intel
#
# Mutated BOTH ways, because a one-way check is what let this through:
#   admit wrongly -> drop the ARM test, Standard_D2ps_v5 must stop planning
#   refuse wrongly -> call Intel unknown, Standard_D2ds_v4 must still plan

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:repoRoot = Join-Path $PSScriptRoot '..' '..'
    $script:dataFile = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json'

    # A catalogue holding the real v6 sizes an Intel, an AMD and an ARM machine
    # would each land on. All three exist in Azure; only two are in the path.
    $script:catalog = @{}
    foreach ($n in 'Standard_D2ds_v6', 'Standard_D2s_v6', 'Standard_D2as_v6', 'Standard_D2ps_v6',
                   'Standard_D2pds_v6', 'Standard_E2ds_v6', 'Standard_DC2as_v6', 'Standard_D2as_v7') {
        $script:catalog[$n] = [pscustomobject]@{ Name = $n; Capabilities = @() }
    }
}

Describe 'SCOPE-DATA-1: the approved target platforms are dated data, not a list in code' {

    It 'the data file exists and parses' {
        Test-Path $script:dataFile | Should -BeTrue
        { Get-Content $script:dataFile -Raw | ConvertFrom-Json } | Should -Not -Throw
    }

    It 'it carries a schema version and the DATE it was read' {
        $doc = Get-Content $script:dataFile -Raw | ConvertFrom-Json
        $doc.schemaVersion | Should -BeGreaterThan 0
        $doc.updatedUtc | Should -Match '^\d{4}-\d{2}-\d{2}'
        [string]$doc.why | Should -Not -BeNullOrEmpty
    }

    It 'and names the Microsoft pages it was read from, so drift has somewhere to land' {
        $doc = Get-Content $script:dataFile -Raw | ConvertFrom-Json
        @($doc.sources).Count | Should -BeGreaterThan 1
        foreach ($s in @($doc.sources)) {
            [string]$s.url | Should -Match '^https://'
            [string]$s.says | Should -Not -BeNullOrEmpty
        }
    }

    It 'Intel and AMD are approved and ARM is NOT' {
        $doc = Get-Content $script:dataFile -Raw | ConvertFrom-Json
        @($doc.approvedProcessors) | Should -Contain 'Intel'
        @($doc.approvedProcessors) | Should -Contain 'AMD'
        @($doc.approvedProcessors) | Should -Not -Contain 'Arm64'
    }

    It 'the letters it reads names by are the documented ones' {
        $doc = Get-Content $script:dataFile -Raw | ConvertFrom-Json
        $doc.processorLetters.a | Should -Be 'AMD'
        $doc.processorLetters.p | Should -Be 'Arm64'
        $doc.defaultProcessor  | Should -Be 'Intel'
    }

    It 'it holds no allowlist of size names for anything to gate on' {
        # The middle column of Microsoft's table says "Examples" and means it.
        # Ddsv6 is absent from it and is this product's commonest target, so a
        # name list would refuse the primary path. Names are kept as EVIDENCE.
        $raw = Get-Content $script:dataFile -Raw
        $raw | Should -Match '(?i)example'
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'Planner.ps1')
        $code | Should -Not -Match 'targetFamilyExamples'
    }
}

Describe 'SCOPE-DATA-1: a size name says which processor it runs on' {

    It 'reads <Size> as <Expected>' -ForEach @(
        @{ Size = 'Standard_D2ds_v6';   Expected = 'Intel' }
        @{ Size = 'Standard_D2s_v6';    Expected = 'Intel' }
        @{ Size = 'Standard_E8-4ds_v5'; Expected = 'Intel' }
        @{ Size = 'Standard_D2_v3';     Expected = 'Intel' }
        @{ Size = 'Standard_D2as_v6';   Expected = 'AMD' }
        @{ Size = 'Standard_E2ads_v5';  Expected = 'AMD' }
        @{ Size = 'Standard_D2ps_v6';   Expected = 'Arm64' }
        @{ Size = 'Standard_D2pds_v6';  Expected = 'Arm64' }
        @{ Size = 'Standard_D2plds_v6'; Expected = 'Arm64' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ size = $Size; expected = $Expected } {
            Get-VmfSizeProcessor -SizeName $size | Should -Be $expected
        }
    }

    It 'and says CANNOT TELL for a name it cannot parse' {
        # Not "out of scope". An unreadable name is a question for a person.
        InModuleScope VmMigrationFactory {
            foreach ($bad in 'nonsense', '', 'Standard_', 'D2ds_v6') {
                $null -eq (Get-VmfSizeProcessor -SizeName $bad) | Should -BeTrue -Because "'$bad' cannot be read"
            }
        }
    }
}

Describe 'SCOPE-DATA-1: the planner refuses a platform Microsoft does not list' {

    It 'an ARM machine no longer plans a migration' {
        # THE DEFECT. Before this, Standard_D2ps_v5 returned Standard_D2ps_v6.
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            foreach ($armSource in 'Standard_D2ps_v5', 'Standard_D2pds_v5', 'Standard_D2plds_v5') {
                $r = Get-VmfTargetSize -SourceSize $armSource -CatalogBySize $c
                $r.Target | Should -BeNullOrEmpty -Because "$armSource is an Ampere ARM machine"
            }
        }
    }

    It 'and is told it is ARM, not that its region is short of sizes' {
        # The same distinction, one level down: a regional shortage is
        # something an operator can act on. Being ARM is not.
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2ps_v5' -CatalogBySize $c
            $r.Reason | Should -Match '(?i)Arm64'
            $r.Reason | Should -Not -Match '(?i)no candidate available in region'
        }
    }

    It 'a confidential machine is refused by its family alone, with no security type in hand' {
        # Second line behind the securityType check in the assessment rules,
        # which needs discovery to have READ a security type. DC and EC are
        # neither D nor E, and no confidential family is in the target table.
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_DC2as_v5' -CatalogBySize $c
            $r.Target | Should -BeNullOrEmpty
        }
    }

    It 'a named size cannot route a machine onto ARM either' {
        # A named size (a chosen one) is checked on the TARGET as well as the
        # source, so no route reaches an ARM size.
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2s_v5' -Size 'Standard_D2ps_v6' -CatalogBySize $c
            $r.Target | Should -BeNullOrEmpty
            $r.Reason | Should -Match '(?i)Arm64'
        }
    }

    It 'a name it cannot read gets a person, not a verdict' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_' -CatalogBySize $c
            $r.Target | Should -BeNullOrEmpty
            $r.Reason | Should -Not -Match '(?i)not part of the v6/v7 migration path'
        }
    }
}

Describe 'SCOPE-DATA-1: and the machines that SHOULD migrate still do' {

    # The other direction. A scope gate that only ever refuses is the failure
    # this item is fixing, pointed the other way.

    It 'an Intel machine still plans onto its v6 size' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            (Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $c).Target |
                Should -Be 'Standard_D2ds_v6'
            (Get-VmfTargetSize -SourceSize 'Standard_E2ds_v5' -CatalogBySize $c).Target |
                Should -Be 'Standard_E2ds_v6'
        }
    }

    It 'an AMD machine still plans, at v6 and at v7' {
        # AMD is in every generation row of the table. Refusing it would be
        # this item's own defect, mirrored.
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            (Get-VmfTargetSize -SourceSize 'Standard_D2as_v4' -CatalogBySize $c).Target |
                Should -Be 'Standard_D2as_v6'
            (Get-VmfTargetSize -SourceSize 'Standard_D2as_v5' -CatalogBySize $c -TargetGeneration 'v7').Target |
                Should -Be 'Standard_D2as_v7'
        }
    }

    It 'and an out-of-scope family still reads as out of scope, not as a platform problem' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_L8s_v3' -CatalogBySize $c
            $r.Target | Should -BeNullOrEmpty
            $r.Reason | Should -Match 'not part of the v6/v7 migration path'
            $r.Reason | Should -Not -Match '(?i)Arm64'
        }
    }
}

Describe 'SCOPE-DATA-1: and the manual says the same thing the code now does' {

    BeforeAll {
        $script:limits = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'limits.md') -Raw
        $script:rows = @($script:limits -split "`r?`n" | Where-Object { $_ -match '^\|\s*(Source|Target) sizes' })
    }

    It 'finds both rows, so this cannot pass by reading nothing' {
        @($script:rows).Count | Should -Be 2
    }

    It 'the source row names the processors, and the support matrix names ARM as out of scope' {
        $source = @($script:rows | Where-Object { $_ -match 'Source sizes' })[0]
        $source | Should -Match '(?i)Intel'
        $source | Should -Match '(?i)AMD'
        # SUPPORT-MATRIX-1: the scope list moved to the support matrix, which
        # is generated. limits.md links to it and keeps no second list.
        $matrix = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'support-matrix.md') -Raw
        $matrix | Should -Match '(?m)^\| Machine on an Arm64 size \|.*\| Not supported \|'
    }

    It 'the target row no longer claims Fasv7 IS the AMD target' {
        # MANUAL-SIZES-1 left "the AMD target is Fasv7". Fasv7 is one of THREE
        # AMD v7 families and is not the one this product produces: the
        # transform keeps the size stem, so an AMD source lands on Dasv7 or
        # Easv7. Nothing reaches Fasv7.
        $target = @($script:rows | Where-Object { $_ -match 'Target sizes' })[0]
        $target | Should -Not -Match '(?i)the AMD target is Fasv7'
        $target | Should -Match 'Dasv7'
        $target | Should -Match 'Easv7'
    }

    It 'and the page and the data file name the same approved processors' {
        # The three-places problem this item exists to end: the page, the data
        # and the code have to be one claim, not three.
        $doc = Get-Content $script:dataFile -Raw | ConvertFrom-Json
        $source = @($script:rows | Where-Object { $_ -match 'Source sizes' })[0]
        foreach ($processor in @($doc.approvedProcessors)) {
            $source | Should -Match "(?i)$processor" -Because 'the manual lists what the data approves'
        }
    }

    It 'the planner really does ask the question the page describes' {
        # Without this, the page becomes a claim about nothing - which is
        # exactly how the manual and the code came apart the first time.
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'Planner.ps1')
        $code | Should -Match 'Get-VmfSizeProcessor'
        $code | Should -Match 'Test-VmfSizeApprovedTarget'
    }
}

Describe 'SCOPE-DATA-1: the two survivors of the first mutation run' {

    # Both of these were written because a mutation LIVED. Ten of twelve were
    # caught; these are the two holes the other ten hid.

    It 'an Arm64 machine whose region has no Arm64 v6 size is still told it is Arm64' {
        # MUTATION A SURVIVED WITHOUT THIS. Dropping the SOURCE check looked
        # harmless, because the TARGET check refuses Standard_D2ps_v6 anyway -
        # but only when the region HAS that size to refuse. Where it does not,
        # the candidate simply misses the catalogue, the D family still has
        # Intel v6 sizes so it is in scope, and the machine is told "no
        # candidate available in region": a regional shortage somebody could
        # wait out or fix by moving region. They cannot. It is the processor.
        InModuleScope VmMigrationFactory {
            $noArm = @{}
            foreach ($n in 'Standard_D2ds_v6', 'Standard_D2s_v6') { $noArm[$n] = [pscustomobject]@{ Name = $n } }
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2ps_v5' -CatalogBySize $noArm
            $r.Target | Should -BeNullOrEmpty
            $r.Reason | Should -Match '(?i)Arm64'
            $r.Reason | Should -Not -Match '(?i)no candidate available in region'
        }
    }

    It 'a name that claims two platforms at once is unknown, not a guess' {
        # MUTATION H SURVIVED WITHOUT THIS. No size Azure ships today carries
        # both letters - but the DATA FILE decides which letters mean what, so
        # one letter added there makes real names ambiguous. Returning
        # whichever platform the file happened to list first would be a silent
        # answer to a question nobody can answer, on a machine somebody is
        # about to migrate.
        InModuleScope VmMigrationFactory {
            $null -eq (Get-VmfSizeProcessor -SizeName 'Standard_D2aps_v6') | Should -BeTrue
        }
    }
}
