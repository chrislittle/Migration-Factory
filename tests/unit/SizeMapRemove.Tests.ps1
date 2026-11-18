#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SIZEMAP-REMOVE-1: the size map file is gone.
#
# New-VmfPlan and New-VmfTargetAdvice took a JSON file of "this source size
# moves to that size" entries (-SizeMapPath) from the first planner on. No
# page, service call or engine operation passed one, so only a person who ran
# the cmdlet by hand could - a way around the target rules the app cannot reach
# (CLAUDE.md rule 12). A machine's size now comes from the rules or from the
# size a person saved on the targets step (Set-VmfTargetChoice), and nothing
# else.
#
# The planner still checks ONE named size against every gate - a saved size
# choice, a size by shape, the AMD size of ADVISE-AN-1 - with Get-VmfTargetSize
# -Size. Every such size is one the product offered, after its own shape check
# (a constrained E size has fewer ACTIVE vCPUs on purpose), so the shape gates
# do not refuse it; the reason says when it is smaller. The default transform
# still never picks a smaller size (SIZE-FIT-1).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
}

Describe 'SIZEMAP-REMOVE-1: no size map reaches the planner or the advice' {
    It 'New-VmfPlan and New-VmfTargetAdvice take no size map file' {
        (Get-Command New-VmfPlan).Parameters.Keys | Should -Not -Contain 'SizeMapPath'
        (Get-Command New-VmfTargetAdvice).Parameters.Keys | Should -Not -Contain 'SizeMapPath'
    }

    It 'no planner or advice function takes a size map' {
        InModuleScope VmMigrationFactory {
            foreach ($name in 'Get-VmfTargetSize', 'Resolve-VmfEntryTarget', 'Get-VmfAdviceOption', 'Get-VmfTargetAdvice') {
                (Get-Command $name).Parameters.Keys | Should -Not -Contain 'SizeMap' -Because "$name must not take a size map"
            }
        }
    }

    It 'no code in the module reads a size map' {
        $files = Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Recurse -Filter '*.ps1'
        $found = foreach ($f in $files) {
            $code = Get-VmfCodeOnly -Path $f.FullName
            if ($code -match '(?i)size[-\s]?map|explicit-map') { $f.Name }
        }
        @($found) | Should -BeNullOrEmpty
    }
}

Describe 'SIZEMAP-REMOVE-1: one named size, checked against every gate' {
    BeforeAll {
        $script:cat = @{
            'Standard_D4_v2'  = [pscustomobject]@{ Name = 'Standard_D4_v2'; Capabilities = @(
                    [pscustomobject]@{ Name = 'vCPUs'; Value = '8' }, [pscustomobject]@{ Name = 'MemoryGB'; Value = '28' },
                    [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '409600' }) }
            'Standard_D4d_v5' = [pscustomobject]@{ Name = 'Standard_D4d_v5'; Capabilities = @(
                    [pscustomobject]@{ Name = 'vCPUs'; Value = '4' }, [pscustomobject]@{ Name = 'MemoryGB'; Value = '16' },
                    [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V1,V2' }) }
            'Standard_D8ds_v5' = [pscustomobject]@{ Name = 'Standard_D8ds_v5'; Capabilities = @(
                    [pscustomobject]@{ Name = 'vCPUs'; Value = '8' }, [pscustomobject]@{ Name = 'MemoryGB'; Value = '32' },
                    [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V1,V2' }) }
        }
    }

    It 'a size that fits is planned, and the reason starts with where it came from' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            param($c)
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4_v2' -Size 'Standard_D8ds_v5' -Why 'chosen-size (test)' -CatalogBySize $c -TargetGeneration 'v5'
            $r.Target | Should -Be 'Standard_D8ds_v5'
            $r.Reason | Should -BeLike 'chosen-size (test)*'
            $r.Reason | Should -Not -BeLike '*size map*'
        }
    }

    It 'a smaller named size is planned with the reason saying so, and the reason names no size map' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            param($c)
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4_v2' -Size 'Standard_D4d_v5' -Why 'chosen-size (test)' -CatalogBySize $c -TargetGeneration 'v5'
            $r.Target | Should -Be 'Standard_D4d_v5'
            $r.Reason | Should -BeLike 'chosen-size (test) (smaller than the machine: Standard_D4_v2 has 8 vCPUs and 28 GiB*'
            $r.Reason | Should -Not -BeLike '*size map*'
        }
    }

    It 'a named size whose shape the catalog does not give is not refused for it - the rule that offered it checked' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            param($c)
            $bare = @{ 'Standard_D4_v2' = $c['Standard_D4_v2']; 'Standard_D8ds_v5' = [pscustomobject]@{ Name = 'Standard_D8ds_v5'; Capabilities = @() } }
            (Get-VmfTargetSize -SourceSize 'Standard_D4_v2' -Size 'Standard_D8ds_v5' -CatalogBySize $bare -TargetGeneration 'v5').Target | Should -Be 'Standard_D8ds_v5'
            # The name rules, with the same catalog, refuse it: the shape cannot be checked.
            $bare['Standard_D4d_v5'] = [pscustomobject]@{ Name = 'Standard_D4d_v5'; Capabilities = @() }
            (Get-VmfTargetSize -SourceSize 'Standard_D4_v2' -CatalogBySize $bare -TargetGeneration 'v5').Code | Should -Be 'shape-unknown'
        }
    }
    It 'the default transform still never picks the smaller size' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            param($c)
            $only = @{ 'Standard_D4_v2' = $c['Standard_D4_v2']; 'Standard_D4d_v5' = $c['Standard_D4d_v5'] }
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4_v2' -CatalogBySize $only -TargetGeneration 'v5'
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'smaller-than-source'
        }
    }

    It 'a named size has no alternates - it is that size or nothing' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            param($c)
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4_v2' -Size 'Standard_D8ds_v5' -CatalogBySize $c -TargetGeneration 'v5'
            @($r.Alternates).Count | Should -Be 0
        }
    }
}
