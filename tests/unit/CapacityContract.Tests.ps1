#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EVAL-M8 and M9 - a contract tested against a fixture is not tested.
#
# Every quota record this tool has ever written was invalid against
# capacity-claim.schema.json, in three ways at once, for as long as the schema
# has existed. Nothing caught it because the only document ever validated
# against that schema was a hand-written sample in schemas/samples/. The sample
# conformed. The code emitted something else, and no test ever compared them.
#
# So these tests validate WHAT THE CODE EMITS. That is only possible because
# the claim now comes out of a pure function, New-VmfCapacityClaim, instead of
# being assembled inline inside a cmdlet full of Azure calls - which is how it
# drifted from its contract unobserved in the first place.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:schemaFile = Join-Path $script:repoRoot 'schemas' 'capacity-claim.schema.json'
    $script:schema = Get-Content $script:schemaFile -Raw | ConvertFrom-Json

    function Script:Claim([hashtable]$Override = @{}) {
        $p = @{
            RunId = 'run-1'; Wave = 'billing-apps'; SubscriptionId = '00000000-0000-0000-0000-000000000000'
            ResourceGroup = 'rg-billing'
            Region = 'centralus'; Zone = $null
            Size = 'Standard_D2ds_v6'; VmFamily = 'StandardDDSv6Family'; State = 'QUOTA_VERIFIED'
            BlockReason = $null; Instances = 4; ReservableInstances = 4; Vcpus = 8
            QuotaLimit = 100; QuotaUsed = 10; Notes = @()
        }
        foreach ($k in $Override.Keys) { $p[$k] = $Override[$k] }
        InModuleScope VmMigrationFactory -Parameters @{ p = $p } { New-VmfCapacityClaim @p }
    }

    function Script:Validates($claim) {
        # SWAP-REFUSED-AFTER-STOP-1: a False from Test-Json is a refusal too - it returns
        # False, and does not throw, for a fault inside a nested list on PowerShell 7.6.7.
        try { $valid = Test-Json -Json ($claim | ConvertTo-Json -Depth 20) -SchemaFile $script:schemaFile -ErrorAction Stop; if (-not $valid) { throw 'The JSON is not valid with the schema.' }; $valid }
        catch { throw "claim is invalid against its own schema: $($_.Exception.Message)" }
    }
}

Describe 'EVAL-M8: what the code emits satisfies the contract' {
    It 'an ordinary verified claim validates' {
        Script:Validates (Script:Claim) | Should -BeTrue
    }

    It 'and it carries checkedUtc, the field that made every claim invalid' {
        # quota is a CLOSED object. checkedUtc was added to the writer so the
        # dashboard could stop implying the reading was live, and never added
        # to the schema - so from that moment every claim failed validation,
        # unconditionally, and no test noticed for weeks.
        $c = Script:Claim
        $c.quota.Keys | Should -Contain 'checkedUtc'
        $script:schema.properties.quota.properties.PSObject.Properties.Name |
            Should -Contain 'checkedUtc'
        $script:schema.properties.quota.additionalProperties | Should -BeFalse `
            -Because 'the closed object is what made an undeclared field fatal, and it should stay closed'
    }

    It 'a claim with an unreadable quota reading validates' {
        # The documented s-suffix v6 listing bug - a PRIMARY fleet shape.
        Script:Validates (Script:Claim @{ QuotaLimit = $null; QuotaUsed = $null }) | Should -BeTrue
    }

    It 'a claim for a size the region does not offer validates' {
        Script:Validates (Script:Claim @{
            VmFamily = $null; State = 'BLOCKED'; BlockReason = 'size-missing' }) | Should -BeTrue
    }

    It 'a failed reservation validates - its reason was outside the enum' {
        Script:Validates (Script:Claim @{
            State = 'BLOCKED'; BlockReason = 'reservation-failed' }) | Should -BeTrue
    }

    It 'every state the schema allows can actually be built' {
        foreach ($st in $script:schema.properties.state.enum) {
            $c = Script:Claim @{ State = $st }
            # OLD-VERSION-READERS-REMOVE-5: a RESERVING record holds what it
            # asked for, which New-VmfWaveReservation adds in the same save.
            if ($st -eq 'RESERVING') {
                $g = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-billing/providers/Microsoft.Compute/capacityReservationGroups/vmf-run-1-billing-apps-00000000-236250ca'
                $c['reservationAsked'] = [ordered]@{ groupId = $g; reservationId = "$g/capacityReservations/d2ds_v6"; askedUtc = '2026-11-12T10:00:00.0000000Z' }
            }
            Script:Validates $c | Should -BeTrue -Because "state '$st' is declared"
        }
    }

    It 'every blockReason the schema allows can actually be built' {
        foreach ($br in @($script:schema.properties.blockReason.enum | Where-Object { $_ })) {
            Script:Validates (Script:Claim @{ State = 'BLOCKED'; BlockReason = $br }) |
                Should -BeTrue -Because "blockReason '$br' is declared"
        }
    }

    It 'guard the guard: an invented field is still rejected' {
        # If Test-Json ignored additionalProperties, every test above would be
        # vacuous - which is precisely the failure mode being fixed.
        $c = Script:Claim
        $c.quota.somethingNobodyDeclared = 'x'
        { Script:Validates $c } | Should -Throw
    }

    It 'QUOTA-FAMILY-1: a claim carrying its family total validates, and one without the field does not' {
        $c = Script:Claim @{ FamilyVcpus = 12 }
        $c.demand.familyVcpus | Should -Be 12
        Script:Validates $c | Should -BeTrue
        # A size with no family has no family total. Null, never 0 - 0 would
        # read as "this family needs nothing".
        $none = Script:Claim @{ VmFamily = $null; State = 'BLOCKED'; BlockReason = 'size-missing' }
        $none.demand.familyVcpus | Should -BeNullOrEmpty
        Script:Validates $none | Should -BeTrue
        # Every claim this version writes holds it (OLD-VERSION-READERS-REMOVE-8).
        $old = Script:Claim
        $old.demand.Remove('familyVcpus')
        { Script:Validates $old } | Should -Throw '*invalid against its own schema*'
    }
    It 'REGIONAL-VCPU-QUOTA-1: a claim carrying the regional ask and reading validates, and one without the ask does not' {
        $c = Script:Claim @{ RegionalVcpus = 6; RegionalLimit = 10; RegionalUsed = 8 }
        $c.demand.regionalVcpus | Should -Be 6
        $c.quota.regionalLimit | Should -Be 10
        $c.quota.regionalUsed | Should -Be 8
        Script:Validates $c | Should -BeTrue
        # Azure did not list the regional quota: null, never 0 - 0 would read
        # as "nothing in use".
        $unread = Script:Claim @{ RegionalVcpus = 6 }
        $null -eq $unread.quota.regionalLimit | Should -BeTrue
        $null -eq $unread.quota.regionalUsed | Should -BeTrue
        Script:Validates $unread | Should -BeTrue
        $blocked = Script:Claim @{ State = 'BLOCKED'; BlockReason = 'regional-quota-shortfall'; RegionalVcpus = 6; RegionalLimit = 10; RegionalUsed = 8 }
        Script:Validates $blocked | Should -BeTrue
        # Every claim this version writes holds the regional ask (OLD-VERSION-READERS-REMOVE-8).
        $old = Script:Claim
        $old.demand.Remove('regionalVcpus')
        { Script:Validates $old } | Should -Throw '*invalid against its own schema*'
    }
    It 'the writer and the schema agree on the version' {
        $declared = InModuleScope VmMigrationFactory { Get-VmfCapacityClaimSchemaVersion }
        $script:schema.properties.schemaVersion.const | Should -Be $declared
        (Script:Claim).schemaVersion | Should -Be $declared
    }
}

Describe 'EVAL-M9: every reason the code writes is a reason the contract knows' {
    It 'the declared reasons and the schema enum are the same set' {
        $declared = InModuleScope VmMigrationFactory { Get-VmfCapacityBlockReasons }
        @($script:schema.properties.blockReason.enum | Where-Object { $_ }) | Sort-Object |
            Should -Be (@($declared) | Sort-Object)
    }

    It 'no cmdlet writes a reason outside that set' {
        # Derived: reservation-failed was written for weeks by a cmdlet, was
        # never in the enum, and nothing compared the two sides.
        $declared = InModuleScope VmMigrationFactory { Get-VmfCapacityBlockReasons }
        $written = foreach ($f in (Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Recurse -Filter '*.ps1')) {
            $t = (Get-VmfPageSource -Path $f.FullName)
            [regex]::Matches($t, "blockReason\s*(?:=|-NotePropertyValue)\s*'([a-z-]+)'") |
                ForEach-Object { $_.Groups[1].Value }
        }
        $strays = @($written | Sort-Object -Unique | Where-Object { $_ -notin $declared })
        $strays -join ', ' | Should -BeNullOrEmpty
    }

    It 'the runway still writes reservation-failed - the value is real, not removed' {
        $runway = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfWaveReservation.ps1') -Raw
        $runway | Should -Match "'reservation-failed'"
    }
}

Describe 'EVAL-M9: a blocked claim cannot render as ready' {
    BeforeAll { . (Join-Path $PSScriptRoot '_PageSource.ps1'); $script:idx = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html')) }

    It 'the pill is decided by the claim STATE, not by one reason string' {
        $fn = [regex]::Match($script:idx, '(?s)function quotaFacet\(c\) \{.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty
        # BLOCKED-NAME-1: the comparison moved into one shared function, because
        # a real install holds claims carrying the OLD value and two pages
        # were asking this question separately.
        $fn | Should -Match 'VmfHelp\.claimBlocked\(c\.state\)'
        $fn | Should -Not -Match "if \(c\.blockReason === 'quota-shortfall'\) return"
    }

    It 'every blocked reason has words of its own, and an unknown one still warns' {
        $declared = InModuleScope VmMigrationFactory { Get-VmfCapacityBlockReasons }
        $map = [regex]::Match($script:idx, '(?s)const BLOCK_TEXT = \{.*?\n\};').Value
        foreach ($r in $declared) { $map | Should -Match ([regex]::Escape($r)) }
        $fn = [regex]::Match($script:idx, '(?s)function quotaFacet\(c\) \{.*?\n\}').Value
        $fn | Should -Match 'quotaBlocked' -Because 'a reason the page has never heard of must not fall through to green'
    }

    It 'a headroom figure that could not be read does not claim to be verified' {
        $fn = [regex]::Match($script:idx, '(?s)function quotaFacet\(c\) \{.*?\n\}').Value
        $fn | Should -Match 'c\.quota\?\.limit == null'
        $fn | Should -Match 'quotaUnknown'
    }
}
