#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# BLOCKED-NAME-1, the stored value. Scoped 2026-09-21, shipped after the
# label half by the rule: language first, store format after.
#
# THE STATE ASSERTED A CAUSE IT WAS WRONG ABOUT THREE TIMES IN FOUR.
# `CAPACITY_BLOCKED` covers four situations and only one is about capacity:
#
#   quota-shortfall     no - a quota is a LIMIT, and Azure had the hardware
#   sku-restricted      no - the size is restricted in that region
#   size-missing        no - the size is not offered there at all
#   reservation-failed  YES - Azure had no capacity to hold
#
# `blockReason` already said which. The state talked over it. It is now
# BLOCKED, and the reason says why - the same shape BLOCK-SAY-1 fixed one
# level up, where a fallback LABEL asserted "not enough quota" for a record
# whose cause was never measured.
#
# OLD-VERSION-READERS-REMOVE-8: no writer gives the earlier name, and nothing
# is public before 1.0, so no store holds it: every reader asks one function,
# which knows BLOCKED only, and a census below proves nothing names the
# earlier one.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')

    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:module   = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
    $script:schema   = Get-Content (Join-Path $script:repoRoot 'schemas' 'capacity-claim.schema.json') -Raw | ConvertFrom-Json
    $script:temp     = New-VmfTestTemp -Prefix 'blockname'
}

AfterAll { Remove-VmfTestTemp }

Describe 'BLOCKED-NAME-1: the state stops naming a cause it does not know' {

    It 'the schema offers BLOCKED' {
        @($script:schema.properties.state.enum) | Should -Contain 'BLOCKED'
    }

    It 'and no longer offers CAPACITY_BLOCKED' {
        @($script:schema.properties.state.enum) | Should -Not -Contain 'CAPACITY_BLOCKED'
    }

    It 'the version the writer declares is the version the schema pins' {
        # Derived on both sides. Two tests used to pin the number and a bump
        # turned into a chore.
        $declared = InModuleScope VmMigrationFactory { Get-VmfCapacityClaimSchemaVersion }
        $script:schema.properties.schemaVersion.const | Should -Be $declared
    }

    It 'and it went up, because a stored value changed' {
        $declared = InModuleScope VmMigrationFactory { Get-VmfCapacityClaimSchemaVersion }
        $declared | Should -BeGreaterThan 7
    }

    It 'all four reasons are still offered, because the reason is what carries the cause now' {
        foreach ($reason in 'quota-shortfall', 'sku-restricted', 'size-missing', 'reservation-failed') {
            @($script:schema.properties.blockReason.enum) | Should -Contain $reason
        }
    }
}

Describe 'BLOCKED-NAME-1: one function decides whether a claim is blocked' {

    It 'says yes to the value this build writes' {
        InModuleScope VmMigrationFactory {
            Test-VmfClaimBlocked -Claim ([pscustomobject]@{ state = 'BLOCKED' }) | Should -BeTrue
        }
    }

    It 'says no to the earlier name, which nothing writes (OLD-VERSION-READERS-REMOVE-8)' {
        InModuleScope VmMigrationFactory {
            Test-VmfClaimBlocked -Claim ([pscustomobject]@{ state = 'CAPACITY_BLOCKED' }) | Should -BeFalse
        }
    }

    It 'says no to every other state' {
        InModuleScope VmMigrationFactory {
            foreach ($state in 'FORECAST', 'QUOTA_VERIFIED', 'QUOTA_REQUESTED', 'RESERVING', 'RESERVED', 'CONSUMED', 'RELEASED') {
                Test-VmfClaimBlocked -Claim ([pscustomobject]@{ state = $state }) |
                    Should -BeFalse -Because "$state is not blocked"
            }
        }
    }

    It 'and says no rather than throwing when there is no state to read' {
        # A claim that could not be read is not a blocked claim; it is an
        # unreadable one, and saying "blocked" would assert a cause again.
        InModuleScope VmMigrationFactory {
            Test-VmfClaimBlocked -Claim $null | Should -BeFalse
            Test-VmfClaimBlocked -Claim ([pscustomobject]@{ wave = 'w1' }) | Should -BeFalse
        }
    }
}

Describe 'BLOCKED-NAME-1: nothing writes the earlier value, and nothing compares to it by hand' {

    # THE CENSUS. One function decides; no file of the module names the
    # earlier value at all (OLD-VERSION-READERS-REMOVE-8).
    It 'no file in the module names CAPACITY_BLOCKED' {
        $offenders = @()
        foreach ($file in Get-ChildItem -Path $script:module -Recurse -Filter '*.ps1') {
            $code = Get-VmfCodeOnly -Path $file.FullName
            if ($code -match 'CAPACITY_BLOCKED') {
                $offenders += $file.FullName.Replace($script:repoRoot, '')
            }
        }
        $offenders | Should -BeNullOrEmpty -Because 'no writer gives it, so no reader takes it'
    }

    It 'and the one function that decides is there, and the state name normaliser is gone' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:module 'Private' 'capacity' 'CapacityClaim.ps1')
        $code | Should -Match 'function Test-VmfClaimBlocked'
        $code | Should -Not -Match 'function Get-VmfClaimStateName'
    }
}

Describe 'BLOCKED-NAME-1: a blocked claim reads the same everywhere' {

    It 'the wave refusal explains a blocked claim' {
        InModuleScope VmMigrationFactory {
            $new = [pscustomobject]@{
                schemaVersion = 15; wave = 'wave-1'; state = 'BLOCKED'
                blockReason = 'reservation-failed'
                notes = @('<what Azure said>')   # rule 13: not a real quote, so it does not look like one
            }
            $said = Get-VmfReservedCapacityRefusal -Claims @($new) -Wave 'wave-1'
            $said | Should -Match '(?i)did not work'
            $said | Should -Match 'reservation-failed'
        }
    }

    It 'the report prints the state as the record holds it' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:module 'Public' 'New-VmfReport.ps1')
        $code | Should -Not -Match 'Pill \$claim\.state'
        $code | Should -Not -Match 'Get-VmfClaimStateName'
        $record = Get-VmfCodeOnly -Path (Join-Path $script:module 'Private' 'report' 'MigrationRecord.ps1')
        $record | Should -Not -Match 'Get-VmfClaimStateName'
    }
}