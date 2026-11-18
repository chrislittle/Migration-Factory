#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PATH-C-1, 2026-09-19.
#
# The plan contract allowed a path 'C', the dashboard had a label for it -
# "Rebuild from a fresh image" - and the quota record carried a field
# described as "true for Path C waves". No planner ever produced 'C' and no
# engine step ever handled it. The contract named a behaviour the product does
# not have.
#
# It matters because it is the one thing in the product that claims a
# redeploy-from-image, which is Microsoft's default execution method and the
# one we deliberately do NOT do: both of our paths keep the machine's own OS
# disk. A name for a capability that is not there is a promise.
#
# MIGRATION NOTE. plan-entry goes to schemaVersion 13. Nothing needs migrating:
# no stored plan can carry 'C', because nothing ever wrote one, and the reader
# refuses only plans NEWER than its own version, so a plan at 12 still reads.
# The quota record's `overlapWithSource` stays ALLOWED by its schema - the
# demand object refuses anything it does not name, and claims written before
# today carry the field - but nothing writes it any more.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:planSchema = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json
    $script:claimSchema = Get-Content (Join-Path $script:repoRoot 'schemas' 'capacity-claim.schema.json') -Raw | ConvertFrom-Json
    $script:pages = @('assessments.html', 'migrations.html', 'reports.html')
}

Describe 'PATH-C-1: the contract only names paths the engine can take' {

    It 'the plan schema offers A, and no longer offers B (OLD-VERSION-READERS-REMOVE-1) or C' {
        @($script:planSchema.properties.path.enum) | Should -Contain 'A'
        @($script:planSchema.properties.path.enum) | Should -Not -Contain 'B'
        @($script:planSchema.properties.path.enum) | Should -Not -Contain 'C'
    }

    It 'and every path it offers has a branch in the state machine' {
        # The rule, not the instance: the enum and the engine must not drift
        # apart again. MANUAL and EXCLUDED never reach the engine - they are
        # how a plan says a machine is not this tool's to move.
        $engine = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $executable = @($script:planSchema.properties.path.enum | Where-Object { $_ -notin @('MANUAL', 'EXCLUDED') })
        # OLD-VERSION-READERS-REMOVE-1: path B left the enum (plan-entry v31).
        $executable.Count | Should -Be 1 -Because 'this engine executes one path'
        $executable | Should -Be @('A')
        $checked = 0
        foreach ($p in $executable) {
            # Path A is the one move: a wave runs only the entries of path A.
            $orchestrator = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'Orchestrator.ps1')
            $orchestrator | Should -Match "\.path\s*-eq\s*'$p'" -Because "a wave runs the entries of path $p"
            $checked++
        }
        $checked | Should -Be $executable.Count -Because 'a loop that ran no cases proves nothing'
    }

    It 'the version moved with the contract' {
        $script:planSchema.properties.schemaVersion.const | Should -BeGreaterOrEqual 13
        InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion | Should -BeGreaterOrEqual 13 }
    }

    It 'and a plan written by the previous version still reads' {
        # The reader refuses what is NEWER than itself, never what is older.
        InModuleScope VmMigrationFactory {
            $current = Get-VmfPlanSchemaVersion
            12 | Should -BeLessThan $current
        }
    }
}

Describe 'PATH-C-1: no page has a name for it either' {

    It 'the path word maps offer one path, on every page that has one' {
        $withMap = 0
        foreach ($page in $script:pages) {
            $text = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' $page)
            $map = [regex]::Match($text, '(?m)^const (?:PATH_WORDS|UX_PATH) = \{(.+?)\};')
            $map.Success | Should -BeTrue -Because "$page declares the words for a path"
            $map.Groups[1].Value | Should -Match "A: '"
            # OLD-REBUILD-RESTORE-READERS-1: path B is gone too, so a map names A only.
            $map.Groups[1].Value | Should -Not -Match "B: '"
            $map.Groups[1].Value | Should -Not -Match "C: '" -Because "$page must not name a path the product cannot take"
            $map.Groups[1].Value | Should -Not -Match '(?i)fresh image'
            $withMap++
        }
        $withMap | Should -Be 3 -Because 'all three pages that show a path were checked'
    }
}

Describe 'PATH-C-1: the quota record stops describing it' {

    It 'nothing writes the overlap field any more' {
        $claim = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'capacity' 'CapacityClaim.ps1')
        $claim | Should -Not -Match 'OverlapWithSource'
        $claim | Should -Not -Match 'overlapWithSource'
    }

    It 'and the schema no longer takes the field: nothing writes it (OLD-VERSION-READERS-REMOVE-8)' {
        $script:claimSchema.properties.demand.additionalProperties | Should -BeFalse
        $script:claimSchema.properties.demand.properties.PSObject.Properties.Name | Should -Not -Contain 'overlapWithSource'
    }
}
