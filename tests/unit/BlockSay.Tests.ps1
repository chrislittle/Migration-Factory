#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# BLOCK-SAY-1, 2026-09-21. Found by checking my own change rather than by a
# test - which is the point of writing these.
#
# WORDS-1 renamed the FALLBACK label for a blocked wave from "Capacity
# blocked" to "Not enough quota". The rename was right about the words and
# wrong about the place: every reason the engine writes has its own words, so
# the fallback is reached only by a record carrying NO reason. It now made a
# SPECIFIC claim - not enough quota - about a record whose cause nobody knows,
# and it would say that about a wave blocked by a failed reservation.
#
# Vague was not the defect. Saying a thing you did not measure is.
#
# THE RULE, NOT THE INSTANCE, in two halves:
#
#   1. A fallback names no cause. It is what is shown when the cause is
#      unknown, so it cannot assert one.
#   2. And every cause the SCHEMA allows has words of its own, so the fallback
#      stays what it is for. Nothing checked this: a fifth reason added to the
#      schema would have fallen silently into the fallback and been described
#      as whatever the fallback happened to say that month.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:page = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html')

    # The reasons the CONTRACT allows, read from the schema rather than listed
    # here - a list here would be the same defect one level up.
    $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'capacity-claim.schema.json') -Raw |
        ConvertFrom-Json
    $script:reasons = @($schema.properties.blockReason.enum | Where-Object { $_ })

    # What the page maps, read from the page.
    $script:mapped = @([regex]::Matches(
        [regex]::Match($script:page, "(?s)const BLOCK_TEXT = \{(.*?)\};").Groups[1].Value,
        "'([a-z-]+)'\s*:") | ForEach-Object { $_.Groups[1].Value })

    # The fallback's words.
    $script:fallback = [regex]::Match($script:page, "quotaBlocked:\s*'([^']*)'").Groups[1].Value
}

Describe 'BLOCK-SAY-1: the fallback names no cause' {

    It 'reads the fallback, so this cannot pass by reading nothing' {
        $script:fallback | Should -Not -BeNullOrEmpty
    }

    It 'and it claims nothing about quota, capacity or a reservation' {
        # The three causes it could be. A fallback that names one of them is
        # telling somebody a thing nobody measured.
        $script:fallback | Should -Not -Match '(?i)quota'
        $script:fallback | Should -Not -Match '(?i)reservation'
        $script:fallback | Should -Not -Match '(?i)restricted|not offered|not available'
    }

    It 'but it still says the wave is blocked' {
        # Claiming nothing is not the same as saying nothing. An empty or
        # cheerful fallback would hide a wave that cannot run.
        $script:fallback | Should -Match '(?i)block'
    }
}

Describe 'BLOCK-SAY-1: every reason the schema allows has words of its own' {

    It 'finds the reasons and the map, so this cannot pass vacuously' {
        @($script:reasons).Count | Should -BeGreaterThan 3
        @($script:mapped).Count | Should -BeGreaterThan 3
    }

    It 'every reason in the schema is mapped on the page' {
        # A reason with no words falls into the fallback, and the fallback
        # deliberately says nothing useful - so an unmapped reason is a wave
        # whose cause the product KNOWS and does not say.
        $unmapped = @($script:reasons | Where-Object { $_ -notin $script:mapped })
        $unmapped -join ', ' | Should -BeNullOrEmpty -Because 'these are causes the engine records and the page cannot name'
    }

    It 'and the page maps no reason the schema does not allow' {
        # The other direction. A mapping for a reason nothing writes is dead
        # words that look like coverage.
        $extra = @($script:mapped | Where-Object { $_ -notin $script:reasons })
        $extra -join ', ' | Should -BeNullOrEmpty -Because 'these name causes the contract does not have'
    }
}

Describe 'BLOCK-SAY-1: the engine always records a reason' {

    It 'no place sets the blocked state without one' {
        # The fallback should be unreachable in practice, and this is what
        # keeps it that way. Read with the parser, not a line filter.
        foreach ($rel in @('Public/Test-VmfQuota.ps1', 'Public/New-VmfWaveReservation.ps1')) {
            $src = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' $rel)
            # ASSIGNMENTS ONLY. The first version matched every mention, so it
            # flagged a `Where-Object state -eq` filter on the blocked state - a READ -
            # and demanded that a filter name a reason. A text search cannot
            # tell a read from a write, which this repository already says out
            # loud about a different check.
                        # BLOCKED-NAME-1 renamed the stored value, and that turned a loose
            # pattern into a wrong one: New-VmfWaveReservation also sets
            # `$status = 'BLOCKED'` on the object it RETURNS, which needs no
            # reason and never had one. The old spelling kept the two apart by
            # accident. Name the field instead - `$state` or `<thing>.state`.
            $sets = [regex]::Matches($src, "\`$(?:[\w.]+\.)?state\s*=\s*'BLOCKED'")
            foreach ($m in $sets) {
                # Either the same line carries the reason, or the next one does.
                $at = $src.IndexOf($m.Value)
                $window = $src.Substring($at, [Math]::Min(220, $src.Length - $at))
                $window | Should -Match 'blockReason' -Because "$rel sets the blocked state without naming why"
            }
        }
    }
}
