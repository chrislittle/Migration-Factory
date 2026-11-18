#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# RESTORE-NAME-STACK-1: a second rollback stacked the disk name.
#
# The TESTMATRIX-1 lab session, 2026-09-30: the first rollback named the OS
# disk '<name>-asitwas-202609301448'; the retry rolled back again and named the
# next one '<name>-asitwas-20-asitwas-202609301614'. The name was CUT to make
# room for the new suffix, and the old suffix was kept in part. A restore
# after a rollback did the same to a data disk: '-d0-asitwa-d0-restored-...'.
#
# The rule now: every product suffix at the END of the name comes off before
# the new one goes on - a complete one always, and a part one an earlier cut
# left only when that name was cut (it is at the length limit). The cut is
# then made from the original part, never from the suffix. The ids below are
# made up.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    function script:DnName([string]$Base, [string]$Suffix) {
        InModuleScope VmMigrationFactory -Parameters @{ b = $Base; s = $Suffix } { param($b, $s) Get-VmfBoundedDiskName -BaseName $b -Suffix $s }
    }
    $script:id = '0123456789abcdef0123456789abcdef'
}

Describe 'RESTORE-NAME-STACK-1: a new suffix replaces the product suffix, it never stacks on it' {
    It 'a name with the suffix <old> gets exactly one new suffix' -TestCases @(
        @{ old = '-asitwas-202609301448' }
        @{ old = '-restored-202609301448' }
        @{ old = '-rtmp-202609301448' }
        @{ old = '-rec-202609301448' }
        @{ old = 'rec-202609301448' }
        @{ old = '-d0-asitwas-202609301448' }
        @{ old = '-d3-restored-202609301448' }
        @{ old = '-d12-rtmp-202609301448' }
    ) {
        param($old)
        DnName "app01-osdisk$old" '-asitwas-202609301614' | Should -Be 'app01-osdisk-asitwas-202609301614'
        DnName "app01-osdisk$old" '-d0-restored-202609301703' | Should -Be 'app01-osdisk-d0-restored-202609301703'
    }

    It 'several complete suffixes stacked by the old rule all come off' {
        DnName 'app01-osdisk-asitwas-202609301448-restored-202609301500-asitwas-202609301614' '-restored-202609301703' |
            Should -Be 'app01-osdisk-restored-202609301703'
    }

    It 'the stacked OS disk name from the lab comes back clean' {
        $stacked = "mx-g1w_OsDisk_1_$($script:id)-asitwas-20-asitwas-202609301614"
        $stacked.Length | Should -Be 80 -Because 'the old rule cut it to exactly the limit'
        DnName $stacked '-asitwas-202609301700' | Should -Be "mx-g1w_OsDisk_1_$($script:id)-asitwas-202609301700"
    }

    It 'the stacked data disk name from the lab comes back clean' {
        $stacked = "mx-wzb_disk2_$($script:id)-d0-asitwa-d0-restored-202609301703"
        $stacked.Length | Should -Be 80
        DnName $stacked '-d0-restored-202609301800' | Should -Be "mx-wzb_disk2_$($script:id)-d0-restored-202609301800"
        DnName $stacked '-d0-rtmp-202609301800' | Should -Be "mx-wzb_disk2_$($script:id)-d0-rtmp-202609301800"
    }

    It 'a chain of part suffixes from several cuts comes off' {
        # asitwas, then a shorter rtmp suffix: the second cut kept part of the first suffix.
        $chain = "mx-g1w_OsDisk_1_$($script:id)-asitwas-20-as-rtmp-202609301614"
        $chain.Length | Should -BeGreaterOrEqual 79
        DnName $chain '-asitwas-202609301700' | Should -Be "mx-g1w_OsDisk_1_$($script:id)-asitwas-202609301700"
    }

    It 'a cut name of 79 characters - the old cut dropped a separator - comes back clean too' {
        # The review found no test at 79: the old cut removed the hyphen it
        # would have ended on, leaving the name one short of the limit.
        $cut79 = "mx-g1w_OsDisk_1_$($script:id)-asitwas-2-asitwas-202609301614"
        $cut79.Length | Should -Be 79
        DnName $cut79 '-asitwas-202609301700' | Should -Be "mx-g1w_OsDisk_1_$($script:id)-asitwas-202609301700"
    }

    It 'repeated rollbacks and restores never change the original part' {
        $name = "mx-g1w_OsDisk_1_$($script:id)"
        $original = $name
        foreach ($s in '-asitwas-202609301448', '-restored-202609301500', '-asitwas-202609301614', '-rtmp-202609301620', '-restored-202609301703', '-asitwas-202609301800') {
            $name = DnName $name $s
            $name | Should -Be "$original$s"
        }
    }
}

Describe 'RESTORE-NAME-STACK-1: the length limit' {
    It 'the longest name Azure accepts still ends in the full new suffix' {
        $longest = 'a' * 80
        $out = DnName $longest '-asitwas-202609301614'
        $out.Length | Should -Be 80
        $out | Should -BeLike '*-asitwas-202609301614'
        $out | Should -Be (('a' * 59) + '-asitwas-202609301614') -Because 'the cut comes from the original part'
    }

    It 'a long original with an old suffix is cut from the original part, and the new suffix is whole' {
        $long = ('b' * 70) + '-restored-202609301448'
        $out = DnName $long '-d1-restored-202609301703'
        $out.Length | Should -Be 80
        $out | Should -Be (('b' * 55) + '-d1-restored-202609301703')
    }

    It 'a name that fits with the new suffix is not cut' {
        $fits = 'c' * 59
        DnName $fits '-asitwas-202609301614' | Should -Be ($fits + '-asitwas-202609301614')
    }

    It 'a cut does not leave a separator before the suffix' {
        DnName (('d' * 58) + '-e' + ('f' * 20)) '-asitwas-202609301614' | Should -Be (('d' * 58) + '-asitwas-202609301614')
    }
}

Describe 'RESTORE-NAME-STACK-1: the customer text in a name stays' {
    It 'a plain name only gains the new suffix' {
        DnName 'app01-osdisk' '-restored-202609301703' | Should -Be 'app01-osdisk-restored-202609301703'
    }

    It 'the customer name <name> keeps its text' -TestCases @(
        @{ name = 'app-restored-data_disk1' }
        @{ name = 'db-asitwas-archive' }
        @{ name = 'app-rtmp-202609301614-logs' }
        @{ name = 'vm1-d1' }
        @{ name = 'vm-data-d' }
        @{ name = 'disk-a' }
        @{ name = 'backup-restored' }
    ) {
        param($name)
        DnName $name '-asitwas-202609301614' | Should -Be "$name-asitwas-202609301614"
    }

    It 'a part-suffix shape in a short name stays: only a name the limit cut can carry a part suffix' {
        # 'disk-a' is not a cut 'asitwas', and 'vm1-d1' is not a cut data suffix.
        DnName 'disk-a-asitwas-202609301448' '-restored-202609301703' | Should -Be 'disk-a-restored-202609301703'
        DnName 'vm1-d1-d1-asitwas-202609291830' '-d1-rtmp-202609301703' | Should -Be 'vm1-d1-d1-rtmp-202609301703'
    }

    It 'a name at the limit with no complete suffix keeps a part-suffix shape at its end' {
        # Only a complete suffix after it shows that a cut made a part suffix.
        # The cut to 80 hides this through Get-VmfBoundedDiskName, so ask the strip itself.
        foreach ($name in (('x' * 77) + '-d1'), (('x' * 73) + '-asitwa')) {
            InModuleScope VmMigrationFactory -Parameters @{ n = $name } { param($n) Remove-VmfDiskNameSuffix -Name $n } | Should -Be $name
        }
    }
}

Describe 'RESTORE-NAME-STACK-1: every derived disk name goes through the one function' {
    It 'no file in the module writes a product disk suffix except as the suffix of Get-VmfBoundedDiskName' {
        $moduleRoot = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
        $found = foreach ($file in Get-ChildItem $moduleRoot -Recurse -Filter '*.ps1') {
            $lines = (Get-VmfCodeOnly -Path $file.FullName) -split "`n"
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '(asitwas|restored|rtmp|rec)-\$' -and $lines[$i] -notmatch 'Get-VmfBoundedDiskName') { "$($file.Name):$($i + 1)" }
            }
        }
        @($found) | Should -BeNullOrEmpty
    }

    # REBUILD-REMOVE-RECOVER-1: the recovery disk names (New-VmfRecoveryDisks)
    # are gone with Rebuild this machine.
}
