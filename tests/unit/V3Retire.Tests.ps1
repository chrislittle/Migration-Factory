#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# V3-RETIRE-1: the retirement dates, and the reader of a size's series.
#
# Microsoft (retirements-and-capacity-restrictions, read 2026-10-03): Dv3,
# Dsv3, Ev3 and Esv3 retire on 2029-11-15 - "you can't create, resize into,
# run, or purchase these sizes" - and the plan page: "you can't fall back to a
# v3 source VM". D, Ds, Dv2 and Dsv2 retire on 2028-05-01; Av2, Amv2, B v1, F,
# Fs and Fsv2 on 2028-11-15.
#
# What a rollback does with them is in V3RetireRollbackSize.Tests.ps1 and
# V3RetireEngine.Tests.ps1. Read from the data; general for every row.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
}

Describe 'V3-RETIRE-1: the dates are data, with their page' {

    BeforeAll { $script:doc = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json }

    It 'every row names its series as Microsoft writes them, how a size name reads, a date and a watched page' {
        $watch = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json
        $pinned = @(foreach ($f in $watch.folders) { foreach ($pg in @($f.pages)) { [string]$pg.name } })
        foreach ($r in @($script:doc.lifecycle.retirements)) {
            @($r.series).Count | Should -BeGreaterThan 0
            @($r.sizeSeries).Count | Should -BeGreaterThan 0
            $r.retiresUtc | Should -Match '^\d{4}-\d{2}-\d{2}$'
            @($script:doc.sources.url | Where-Object { $_ -match "/$([regex]::Escape([string]$r.source))$" }).Count | Should -Be 1
            $pinned | Should -Contain ([string]$r.source) -Because 'upstream-docs.json v2 names a page without its .md'
        }
    }

    It 'holds the dates Microsoft gives' -ForEach @(
        @{ Size = 'Standard_D4s_v3'; Date = '2029-11-15' }
        @{ Size = 'Standard_D4_v3'; Date = '2029-11-15' }
        @{ Size = 'Standard_E64is_v3'; Date = '2029-11-15' }
        @{ Size = 'Standard_E8-4s_v3'; Date = '2029-11-15' }
        @{ Size = 'Standard_D4_v2'; Date = '2028-05-01' }
        @{ Size = 'Standard_DS13-4_v2'; Date = '2028-05-01' }
        @{ Size = 'Standard_DS2_v2_Promo'; Date = '2028-05-01' }
        @{ Size = 'Standard_D4'; Date = '2028-05-01' }
        @{ Size = 'Standard_DS3'; Date = '2028-05-01' }
        @{ Size = 'Standard_A2m_v2'; Date = '2028-11-15' }
        @{ Size = 'Standard_A4_v2'; Date = '2028-11-15' }
        @{ Size = 'Standard_B2ms'; Date = '2028-11-15' }
        @{ Size = 'Standard_B1ls'; Date = '2028-11-15' }
        @{ Size = 'Standard_F4s_v2'; Date = '2028-11-15' }
        @{ Size = 'Standard_F4'; Date = '2028-11-15' }
        @{ Size = 'standard_d4s_v3'; Date = '2029-11-15' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Size; d = $Date } {
            (Get-VmfSizeRetirement -SizeName $s).RetiresUtc | Should -Be $d
        }
    }

    It 'a size with no announced retirement has none: <Size>' -ForEach @(
        @{ Size = 'Standard_D4s_v4' }; @{ Size = 'Standard_D4ds_v5' }; @{ Size = 'Standard_D4ds_v6' }
        @{ Size = 'Standard_B2s_v2' }; @{ Size = 'Standard_E4as_v4' }; @{ Size = 'nonsense' }; @{ Size = '' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Size } {
            Get-VmfSizeRetirement -SizeName $s | Should -BeNullOrEmpty
        }
    }
}

Describe 'V3-RETIRE-1: warn from 12 months before, refuse from the date' {

    It '<When>: <State>' -ForEach @(
        @{ When = '2026-10-03T12:00:00Z'; State = 'none' }
        @{ When = '2028-11-14T23:59:59Z'; State = 'none' }
        @{ When = '2028-11-15T00:00:00Z'; State = 'warn' }
        @{ When = '2029-11-14T23:59:59Z'; State = 'warn' }
        @{ When = '2029-11-15T00:00:00Z'; State = 'refused' }
        @{ When = '2031-01-01T00:00:00Z'; State = 'refused' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ w = $When; s = $State } {
            $now = [datetime]::Parse($w, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            $r = Get-VmfPutBackRetirement -SizeName 'Standard_D4s_v3' -Now $now
            $r.State | Should -Be $s
            $r.RetiresUtc | Should -Be '2029-11-15'
            $r.WarnFromUtc | Should -Be '2028-11-15'
        }
    }

    It 'the rule is the data''s, not v3''s: a row added to the data is obeyed' {
        InModuleScope VmMigrationFactory {
            $f = (Get-VmfTargetFamilyData) | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            $f.lifecycle.retirements = @([pscustomobject]@{ series = @('Dsv4'); sizeSeries = @('Dsv4'); retiresUtc = '2027-01-01'; source = 'x' })
            (Get-VmfPutBackRetirement -SizeName 'Standard_D4s_v4' -Now ([datetime]'2026-06-01') -Families $f).State | Should -Be 'warn'
            (Get-VmfPutBackRetirement -SizeName 'Standard_D4s_v3' -Now ([datetime]'2030-06-01') -Families $f).State | Should -Be 'none'
        }
    }

    It 'a size with no entry is never refused' {
        InModuleScope VmMigrationFactory {
            (Get-VmfPutBackRetirement -SizeName 'Standard_D4s_v4' -Now ([datetime]'2040-01-01')).State | Should -Be 'none'
        }
    }
}
