#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# OLD-VERSION-READERS-REMOVE-5: the release of an on-demand capacity
# reservation, and the read of one being made, take the resource IDs the quota
# record recorded - never a name made by the rule from before CLAIM-NAME-1.
#
# Since 2026-11-11: nothing is public before 1.0, so no store holds a record
# an earlier version wrote. The proof that every record this version gives the
# release carries what the release now needs:
#   - The release's stuck path and the read take a RESERVING record only
#     (Test-VmfClaimReservingStuck, Get-VmfReservingClaims).
#   - Only New-VmfWaveReservation writes RESERVING, and it writes
#     reservationAsked in the same save (tested below on what it saves).
#   - The contract refuses a RESERVING record with no reservationAsked.
#   - The held path (RESERVED, CONSUMED) reads the record's own reservation ids.
# A record that holds none is refused, and nothing is released by a guessed name.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:temp = New-VmfTestTemp -Prefix 'ovr5'
    $script:schemaText = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'schemas' 'capacity-claim.schema.json'))

    $script:sub = '00000000-0000-0000-0000-000000000000'
    $script:gid = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/vmf-r1-w1-00000000-236250ca"
    $script:old = [datetime]::UtcNow.AddHours(-3).ToString('o')

    function Global:Ovr5Claim {
        param([string]$State = 'RESERVING', [string]$Size = 'Standard_D2s_v6', [string]$Wave = 'w1', [hashtable]$Extra = @{})
        $claim = [ordered]@{
            schemaVersion = 15; runId = 'r1'; wave = $Wave; subscriptionId = '00000000-0000-0000-0000-000000000000'
            resourceGroup = 'rg-app'; region = 'centralus'; zone = $null
            size = $Size; vmFamily = 'StandardDSv6Family'; state = $State; blockReason = $null
            demand = [ordered]@{ instances = 2; reservableInstances = 2; ownGroupVmIds = @(); vcpus = 4; familyVcpus = 4; regionalVcpus = 0; regionalAdds = 0 }
            notes = @()
        }
        foreach ($k in $Extra.Keys) { $claim[$k] = $Extra[$k] }
        $claim
    }
    function Global:Ovr5Run {
        $rp = Join-Path $script:temp "r-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'ovr5' | Out-Null }
        $rp
    }
    function Global:Ovr5Put { param($RunPath, $Name, $Claim)
        $dir = Join-Path $RunPath 'capacity'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $Claim | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $dir "$Name.json") -Encoding utf8NoBOM
    }
    function Global:Ovr5Read { param($RunPath, $Name) Get-Content (Join-Path $RunPath 'capacity' "$Name.json") -Raw | ConvertFrom-Json -DateKind String }
    function Global:Ovr5Lines { param($RunPath)
        $f = Join-Path $RunPath 'logs' 'events.jsonl'
        if (-not (Test-Path $f)) { return @() }
        @(Get-Content $f | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.step -eq 'odcr' })
    }
}

AfterAll {
    Remove-VmfTestTemp
    Remove-Variable -Name Ovr5SeenText -Scope Global -ErrorAction SilentlyContinue
    Remove-Item 'function:\Ovr5Claim', 'function:\Ovr5Run', 'function:\Ovr5Put', 'function:\Ovr5Read', 'function:\Ovr5Lines' -ErrorAction SilentlyContinue
}

Describe 'OLD-VERSION-READERS-REMOVE-5: the names of an on-demand capacity reservation come from its record' {
    It 'a record with no recorded ask is refused, never given the names of the rule from before CLAIM-NAME-1' {
        $c = [pscustomobject](Ovr5Claim)
        InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
            param($c)
            { Get-VmfReservationNames -Claim $c } | Should -Throw '*Standard_D2s_v6 in centralus holds no resource ID for an on-demand capacity reservation*'
        }
    }

    It 'a recorded ask with only <Missing> missing is refused' -ForEach @(@{ Missing = 'groupId' }, @{ Missing = 'reservationId' }) {
        $asked = [ordered]@{ groupId = $script:gid; reservationId = "$($script:gid)/capacityReservations/d2s_v6"; askedUtc = $script:old }
        $asked[$Missing] = ''
        $c = [pscustomobject](Ovr5Claim -Extra @{ reservationAsked = [pscustomobject]$asked })
        InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
            param($c)
            { Get-VmfReservationNames -Claim $c } | Should -Throw '*holds no resource ID*'
        }
    }

    It 'a recorded ask gives its own names, read from the IDs' {
        $c = [pscustomobject](Ovr5Claim -Extra @{ reservationAsked = [pscustomobject]@{ groupId = $script:gid; reservationId = "$($script:gid)/capacityReservations/d2s_v6"; askedUtc = $script:old } })
        InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
            param($c)
            $n = Get-VmfReservationNames -Claim $c
            $n.GroupName | Should -BeExactly 'vmf-r1-w1-00000000-236250ca'
            $n.ReservationName | Should -BeExactly 'd2s_v6'
            $n.ResourceGroup | Should -BeExactly 'rg-app'
        }
    }

    It 'the rule from before CLAIM-NAME-1 is gone from the code' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'capacity' 'CapacityClaim.ps1')
        $code | Should -Not -Match 'Length -gt 76' -Because 'only the old rule cut a group name at 76 characters with no code after it'
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-5: the release' {
    It 'releases a current record by the resource IDs it recorded' {
        $rp = Ovr5Run
        Ovr5Put $rp 'c1' (Ovr5Claim -Extra @{ reservingSinceUtc = $script:old
            reservationAsked = [ordered]@{ groupId = $script:gid; reservationId = "$($script:gid)/capacityReservations/d2s_v6"; askedUtc = $script:old } })
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
        Mock -ModuleName VmMigrationFactory Test-VmfCapacityReservationPresent { $false }
        $r = Remove-VmfCapacityReservations -OutPath $rp -Wave 'w1'
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservation -Times 1 -Exactly -ParameterFilter {
            $GroupName -eq 'vmf-r1-w1-00000000-236250ca' -and $ReservationName -eq 'd2s_v6' -and $ResourceGroupName -eq 'rg-app' -and $SubscriptionId -eq '00000000-0000-0000-0000-000000000000' }
        (Ovr5Read $rp 'c1').state | Should -Be 'RELEASED'
        @($r.Released).Count | Should -Be 1
    }

    It 'refuses a record with no recorded ask: nothing is asked of Azure, the record stays, and the step line says why' {
        $rp = Ovr5Run
        Ovr5Put $rp 'c1' (Ovr5Claim -Extra @{ reservingSinceUtc = $script:old })
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
        Mock -ModuleName VmMigrationFactory Test-VmfCapacityReservationPresent { $false }
        $r = Remove-VmfCapacityReservations -OutPath $rp -Wave 'w1'
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservation -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfCapacityReservationPresent -Times 0 -Exactly
        $c = Ovr5Read $rp 'c1'
        $c.state | Should -Be 'RESERVING'
        $c.PSObject.Properties['reservation'] | Should -BeNullOrEmpty
        @($r.NotReleased).Count | Should -Be 1
        @($r.Released).Count | Should -Be 0
        $line = @(Ovr5Lines $rp | Where-Object outcome -eq 'fail')
        $line.Count | Should -Be 1
        $line[0].detail | Should -BeExactly ('The quota record for Standard_D2s_v6 in centralus holds no resource ID for an on-demand capacity reservation, so nothing was released. ' +
            'An on-demand capacity reservation can still bill. Find it in Azure by the tag vmfCapacityReservation=true, then delete it there.')
    }

    It 'releases nothing else: only the current record of this wave goes, by its own IDs' {
        $rp = Ovr5Run
        $heldGid = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/vmf-r1-w1-00000000-11111111"
        $otherGid = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/vmf-r1-w2-00000000-22222222"
        Ovr5Put $rp 'a-noask' (Ovr5Claim -Extra @{ reservingSinceUtc = $script:old })
        Ovr5Put $rp 'b-held' (Ovr5Claim -State 'RESERVED' -Size 'Standard_E2s_v6' -Extra @{
            reservation = [ordered]@{ groupId = $heldGid; reservationId = "$heldGid/capacityReservations/e2s_v6"; createdUtc = $script:old; releasedUtc = $null; consumedInstances = 0 } })
        Ovr5Put $rp 'c-other-wave' (Ovr5Claim -State 'RESERVED' -Wave 'w2' -Extra @{
            reservation = [ordered]@{ groupId = $otherGid; reservationId = "$otherGid/capacityReservations/d2s_v6"; createdUtc = $script:old; releasedUtc = $null; consumedInstances = 0 } })
        Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservation { }
        Mock -ModuleName VmMigrationFactory Set-VmfCapacityReservationQuantity { }
        Mock -ModuleName VmMigrationFactory Test-VmfCapacityReservationPresent { $false }
        $r = Remove-VmfCapacityReservations -OutPath $rp -Wave 'w1'
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservation -Times 1 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfCapacityReservation -Times 1 -Exactly -ParameterFilter {
            $GroupName -eq 'vmf-r1-w1-00000000-11111111' -and $ReservationName -eq 'e2s_v6' }
        (Ovr5Read $rp 'a-noask').state | Should -Be 'RESERVING'
        (Ovr5Read $rp 'b-held').state | Should -Be 'RELEASED'
        (Ovr5Read $rp 'c-other-wave').state | Should -Be 'RESERVED'
        @($r.Released).Count | Should -Be 1
        @($r.NotReleased).Count | Should -Be 1
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-5: the read of a record being made' {
    It 'a record with no recorded ask is not read from Azure and is not changed' {
        $rp = Ovr5Run
        Ovr5Put $rp 'c1' (Ovr5Claim -Extra @{ reservingSinceUtc = $script:old })
        Mock -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm { [pscustomobject]@{ Found = $false; ProvisioningState = $null; TimeCreated = $null } }
        $before = Get-Content (Join-Path $rp 'capacity' 'c1.json') -Raw
        $reads = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Get-VmfReservingClaims -RunPath $rp })
        $reads.Count | Should -Be 1
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; r = $reads[0] } { param($rp, $r) Update-VmfReservingClaimFromAzure -RunPath $rp -Read $r } } |
            Should -Throw '*holds no resource ID for an on-demand capacity reservation*'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfCapacityReservationByArm -Times 0 -Exactly
        Get-Content (Join-Path $rp 'capacity' 'c1.json') -Raw | Should -BeExactly $before
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-5: every RESERVING record carries its ask' {
    It 'the contract refuses a RESERVING record with no reservationAsked' {
        ((Ovr5Claim -Extra @{ reservingSinceUtc = $script:old }) | ConvertTo-Json -Depth 8) |
            Test-Json -Schema $script:schemaText -ErrorAction SilentlyContinue | Should -BeFalse
        ((Ovr5Claim -Extra @{ reservingSinceUtc = $script:old
            reservationAsked = [ordered]@{ groupId = $script:gid; reservationId = "$($script:gid)/capacityReservations/d2s_v6"; askedUtc = $script:old } }) | ConvertTo-Json -Depth 8) |
            Test-Json -Schema $script:schemaText -ErrorAction SilentlyContinue | Should -BeTrue
    }

    It 'the contract still takes a record at <State> with no reservationAsked' -ForEach @(@{ State = 'QUOTA_VERIFIED' }, @{ State = 'BLOCKED' }, @{ State = 'FORECAST' }) {
        $c = Ovr5Claim -State $State
        if ($State -eq 'BLOCKED') { $c.blockReason = 'quota-shortfall' }
        ($c | ConvertTo-Json -Depth 8) | Test-Json -Schema $script:schemaText -ErrorAction SilentlyContinue | Should -BeTrue
    }

    It 'only New-VmfWaveReservation writes RESERVING, and only once' {
        # Review: every way a writer can set the state - an assignment or a
        # property in single or double quotes, Add-Member's value, a -State
        # argument - counted per match, so a second writer in the same file
        # fails too.
        $writes = '(?i)(\bstate\s*[=:]\s*|-(NotePropertyValue|Value|State)\s+)[''"]RESERVING[''"]'
        $found = @(Get-ChildItem -Path (Join-Path $script:repoRoot 'src') -Recurse -Include '*.ps1', '*.psm1', '*.js' | ForEach-Object {
                $name = $_.Name
                foreach ($m in [regex]::Matches((Get-VmfCodeOnly -Path $_.FullName), $writes)) { "${name}: $($m.Value)" }
            })
        $found | Should -Be @("New-VmfWaveReservation.ps1: state = 'RESERVING'")
    }

    It 'the RESERVING record Reserve saves, before it asks Azure, is valid against the contract' {
        $rp = Ovr5Run
        Ovr5Put $rp 'c1' (Ovr5Claim -State 'QUOTA_VERIFIED')
        $global:Ovr5SeenText = $null
        $file = Join-Path $rp 'capacity' 'c1.json'
        Mock -ModuleName VmMigrationFactory Get-VmfReservedCoverageGaps { @() }
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
            $global:Ovr5SeenText = Get-Content $file -Raw
            @{ GroupId = '/g'; ReservationId = '/g/r' }
        }.GetNewClosure()
        New-VmfWaveReservation -OutPath $rp -Wave 'w1' | Out-Null
        $global:Ovr5SeenText | Should -Not -BeNullOrEmpty
        ($global:Ovr5SeenText | ConvertFrom-Json).state | Should -Be 'RESERVING'
        $global:Ovr5SeenText | Test-Json -Schema $script:schemaText -ErrorAction SilentlyContinue | Should -BeTrue
    }
}
