#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STORAGE-CONTRACT-1 - the before and after scripts must describe storage the
# SAME WAY, or the comparison between them is not a comparison.
#
# FOUND BY THE VOLUME DRILL, 2026-09-01. The drill proved a customer's Storage
# Spaces pool DOES survive a Path B recreate - and then found that the engine
# could not tell:
#
#   Test-NvmeReady.ps1      (prep, source of the BEFORE capture)
#       -> 'storage pools', 'storage volumes'          [aggregated]
#   Test-GuestValidation.ps1 (the AFTER validator)
#       -> 'storage pool <name>', 'storage volume <name>'   [per pool]
#
# Get-VmfStorageFacts matches the aggregated names exactly, so the after side
# reported nothing it recognised and the verdict was UNKNOWN - neither pass nor
# fail. The check therefore protected NOTHING on any machine that actually had a
# pool. Machines with none compared fine, which is exactly why it looked healthy:
# the validator emitted the bare 'storage pools' only in its no-pools and
# could-not-inspect branches.
#
# 17 unit tests pinned the comparison logic. None of them could see this, because
# they feed the comparison hand-written fixtures rather than what the two scripts
# actually emit. That is the gap this file closes.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:prep      = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Test-NvmeReady.ps1') -Raw
    $script:validator = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Test-GuestValidation.ps1') -Raw

    # The names the ENGINE actually looks for, read out of the engine rather
    # than restated here - so renaming a check in one place fails this test
    # instead of silently going UNKNOWN in production.
    $facts = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'validate' 'RebuildFidelity.ps1') -Raw
    $body = [regex]::Match($facts, "(?ms)function Get-VmfStorageFacts \{.*?\n\}").Value
    $script:engineNames = [regex]::Matches($body, "& \`$get '([^']+)'") |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
}

Describe 'STORAGE-CONTRACT-1: both scripts speak the names the engine reads' {
    It 'found the engine names it parses' {
        @($script:engineNames).Count | Should -BeGreaterThan 3
        $script:engineNames | Should -Contain 'storage pools'
        $script:engineNames | Should -Contain 'storage volumes'
    }

    It 'the PREP script emits the aggregated Windows names' {
        foreach ($n in 'storage pools', 'storage volumes') {
            $script:prep | Should -Match "Add-Check '$n'" -Because "the before capture must contain '$n'"
        }
    }

    It 'and so does the VALIDATOR - this is the bug the drill found' {
        # Without this the after side reports per-pool names only, the engine
        # recognises none of them, and the verdict is UNKNOWN on exactly the
        # machines the check exists to protect.
        foreach ($n in 'storage pools', 'storage volumes') {
            $script:validator | Should -Match "Add-Check '$n'" -Because "the after report must contain '$n'"
        }
    }

    It 'the validator emits them when pools EXIST, not only when there are none' {
        # The original code did emit 'storage pools' - but only in the no-pools
        # and could-not-inspect branches. That is why it looked healthy.
        # Precisely the pools-EXIST branch: from the `if` up to its `else`. The
        # first version of this matched loosely enough to swallow the else
        # branch as well, so it passed while the bug was still present - which
        # a mutation test caught. A guard that cannot fail is not a guard.
        $block = [regex]::Match($script:validator,
            '(?ms)if \(\$pools\.Count -gt 0\) \{(.*?)^        else \{').Groups[1].Value
        $block | Should -Not -BeNullOrEmpty -Because 'the pools-exist branch must be findable'
        # The AGGREGATED emission specifically - a per-pool name starts with the
        # same words and would satisfy a looser match.
        $block | Should -Match "Add-Check 'storage pools' 'INFO' \(\(\`$pools"
        $block | Should -Match "Add-Check 'storage volumes' 'INFO' \(\(\`$allVds"
    }

    It 'and both use the same value format, so one parser reads both' {
        # 'Name[health=...;disks=N]' - the shape Get-VmfStorageFacts counts by
        # matching '[health='.
        foreach ($src in $script:prep, $script:validator) {
            $src | Should -Match '\[health=\$\(\$_\.HealthStatus\);disks='
        }
    }
}

Describe 'STORAGE-CONTRACT-1: the engine reads what the scripts write' {
    It 'a pool reported the aggregated way is COUNTED, not ignored' {
        InModuleScope VmMigrationFactory {
            $after = [pscustomobject]@{ checks = @(
                [pscustomobject]@{ name = 'storage pools';   detail = 'AppPool[health=Healthy;disks=2]' }
                [pscustomobject]@{ name = 'storage volumes'; detail = 'AppData[health=Healthy;state=OK]' }
            ) }
            $f = Get-VmfStorageFacts -GuestOutput $after
            $f.Reported | Should -BeTrue
            $f.Groups   | Should -Be 1
            $f.Volumes  | Should -Be 1
        }
    }

    It 'and the before/after pair the drill actually produced compares as MATCH' {
        # The exact documents, in the exact shapes, that returned UNKNOWN on
        # 2026-09-01. This is the regression.
        InModuleScope VmMigrationFactory {
            $doc = {
                [pscustomobject]@{ checks = @(
                    [pscustomobject]@{ name = 'storage pools';   detail = 'AppPool[health=Healthy;disks=2]' }
                    [pscustomobject]@{ name = 'storage volumes'; detail = 'AppData[health=Healthy;state=OK]' }
                ) }
            }
            $r = Test-VmfStorageTopology -Before (& $doc) -After (& $doc)
            $r.Verdict | Should -Be 'MATCH' -Because 'this pair returned UNKNOWN before the fix'
            $r.Ok      | Should -BeTrue
        }
    }

    It 'a pool that came back a disk short is still a MISMATCH' {
        # Making the check report must not make it toothless.
        InModuleScope VmMigrationFactory {
            $before = [pscustomobject]@{ checks = @(
                [pscustomobject]@{ name = 'storage pools'; detail = 'AppPool[health=Healthy;disks=2]' }) }
            $after = [pscustomobject]@{ checks = @(
                [pscustomobject]@{ name = 'storage pools'; detail = 'AppPool[health=Degraded;disks=1]' }
                [pscustomobject]@{ name = 'storage pool disks missing'; detail = 'MISSING: PhysicalDisk2=Lost' }) }
            $r = Test-VmfStorageTopology -Before $before -After $after
            $r.Verdict | Should -Be 'MISMATCH'
            $r.Ok      | Should -BeFalse
        }
    }
}
