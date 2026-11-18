#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-EDIT-RESERVE-1: a wave editor save must never delete the record of a
# capacity reservation that bills.
#
# Found by the independent review of WAVE-MIX-2: Set-VmfWavePlan removed every
# claim of a wave it touched, in any state. A claim held in Azure (RESERVING,
# RESERVED, CONSUMED) is the only record of an on-demand capacity reservation,
# so the reservation kept billing with nothing in the product pointing at it -
# and changing any setting walked round Set-VmfMachineTarget's refusal.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:vm1 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
    $script:vm2 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2'
    function Global:WrRun([string]$State1) {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; a = $script:vm1; b = $script:vm2; s1 = $State1 } {
            Initialize-VmfRun -RunPath $rp -RunId 'wr-test' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = 8; assessmentRunId = 'wr-test'
                entries = @(
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $a; wave = 'wave-1'; path = 'A'
                        assessment = [ordered]@{ location = 'centralus' }; target = [ordered]@{ size = 'Standard_D2ds_v6' }
                        policy = [ordered]@{ capacityGate = 'Reserved'; requireApproval = $true; onDDataFound = 'stop' } }
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $b; wave = 'wave-2'; path = 'A'
                        assessment = [ordered]@{ location = 'centralus' }; target = [ordered]@{ size = 'Standard_D2ds_v6' }
                        policy = [ordered]@{ capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop' } })
            })
            $claim = [ordered]@{ schemaVersion = 8; wave = 'wave-1'; region = 'centralus'; size = 'Standard_D2ds_v6'; count = 1; state = $s1 }
            if ($s1 -in @('RESERVED', 'CONSUMED', 'RELEASED')) {
                $claim.reservation = [ordered]@{ createdUtc = '2026-09-20T10:00:00Z'; releasedUtc = $(if ($s1 -eq 'RELEASED') { '2026-09-21T10:00:00Z' } else { $null }) }
            }
            Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/wave-1-d2ds.json' -Depth 12 -Document $claim
        }
        $rp
    }
    # A save that changes one setting on wave-1, which touches it.
    function Global:WrSave($rp) {
        Set-VmfWavePlan -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -ChangedBy 'operator@example.com' -Confirm:$false -Layout @{
            waves = @(
                @{ name = 'wave-1'; vmIds = @($script:vm1); capacityGate = 'Reserved'; requireApproval = $true; onDDataFound = 'proceed' }
                @{ name = 'wave-2'; vmIds = @($script:vm2); capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop' })
        }
    }
}
AfterAll { Remove-Item 'function:\WrRun', 'function:\WrSave' -ErrorAction SilentlyContinue }

Describe 'WAVE-EDIT-RESERVE-1: a save never deletes a reservation that bills' {
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'refuses while the wave has a reservation <State>, and changes nothing' -ForEach @(
        @{ State = 'RESERVING' }, @{ State = 'RESERVED' }, @{ State = 'CONSUMED' }) {
        $script:rp = WrRun $State
        $before = Get-Content (Join-Path $script:rp 'plan.json') -Raw
        { WrSave $script:rp } | Should -Throw "400: Wave wave-1 has an on-demand capacity reservation*($State)*release it on the wave*"
        Get-Content (Join-Path $script:rp 'plan.json') -Raw | Should -BeExactly $before
        Test-Path (Join-Path $script:rp 'capacity' 'wave-1-d2ds.json') | Should -BeTrue
    }

    It 'refuses a rename too: the claim of a wave that no longer exists would be removed' {
        $script:rp = WrRun 'RESERVED'
        { Set-VmfWavePlan -RunPath $script:rp -PlanPath (Join-Path $script:rp 'plan.json') -ChangedBy 'operator@example.com' -Confirm:$false -Layout @{
                waves = @(@{ name = 'renamed'; vmIds = @($script:vm1) }, @{ name = 'wave-2'; vmIds = @($script:vm2) }) } } |
            Should -Throw '400: Wave wave-1 has an on-demand capacity reservation in Azure*'
        Test-Path (Join-Path $script:rp 'capacity' 'wave-1-d2ds.json') | Should -BeTrue
    }

    It 'a quota check is still cleared, as before' {
        $script:rp = WrRun 'QUOTA_VERIFIED'
        $r = WrSave $script:rp
        @($r.CapacityChecksCleared) | Should -Be @('wave-1')
        Test-Path (Join-Path $script:rp 'capacity' 'wave-1-d2ds.json') | Should -BeFalse
    }

    It 'a RELEASED record bills nothing: it is cleared, and the activity log keeps what it said' {
        # Kept, it would stop the wave starting again - the start check reads a
        # released claim as not ready. So it goes, but not silently.
        $script:rp = WrRun 'RELEASED'
        $r = WrSave $script:rp
        @($r.CapacityChecksCleared) | Should -Be @('wave-1')
        $ev = InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp } { Read-VmfEvents -RunPath $p -Step 'capacity' }
        @($ev | Where-Object { $_.detail -match 'released on-demand capacity reservation' -and $_.detail -match 'Standard_D2ds_v6' -and $_.detail -match 'centralus' }).Count |
            Should -Be 1
    }

    It 'a reserve job that turns the quota check into a reservation during the save stops it' {
        $script:rp = WrRun 'QUOTA_VERIFIED'
        $script:reads = 0
        Mock -ModuleName VmMigrationFactory Read-VmfStoreJson {
            $script:reads++
            [pscustomobject]@{ wave = 'wave-1'; region = 'centralus'; size = 'Standard_D2ds_v6'; state = $(if ($script:reads -ge 2) { 'RESERVING' } else { 'QUOTA_VERIFIED' }) }
        } -ParameterFilter { $RelPath -like 'capacity/*' }
        $before = Get-Content (Join-Path $script:rp 'plan.json') -Raw
        { WrSave $script:rp } | Should -Throw '400: Wave wave-1 has an on-demand capacity reservation that Azure is still making (RESERVING)*'
        Get-Content (Join-Path $script:rp 'plan.json') -Raw | Should -BeExactly $before
        Test-Path (Join-Path $script:rp 'capacity' 'wave-1-d2ds.json') | Should -BeTrue
    }
}

Describe 'STEP-LOG-4: a wave save line that cannot be written, after the plan is saved' {
    BeforeAll {
        # The save WrSave makes, called here so the warning can be read.
        $script:wrLayout = @{
            waves = @(
                @{ name = 'wave-1'; vmIds = @($script:vm1); capacityGate = 'Reserved'; requireApproval = $true; onDDataFound = 'proceed' }
                @{ name = 'wave-2'; vmIds = @($script:vm2); capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop' })
        }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'the line for a check that became a reservation cannot be written: the next quota check is still removed' {
        $script:rp = WrRun 'QUOTA_VERIFIED'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/wave-1-a-d4ds.json' -Depth 12 -Document ([ordered]@{
                schemaVersion = 8; wave = 'wave-1'; region = 'centralus'; size = 'Standard_D4ds_v6'; count = 1; state = 'QUOTA_VERIFIED' })
        }
        # The third read of this record - after the plan is saved - finds a reservation.
        $script:aReads = 0
        Mock -ModuleName VmMigrationFactory Read-VmfStoreJson {
            $script:aReads++
            [pscustomobject]@{ wave = 'wave-1'; region = 'centralus'; size = 'Standard_D4ds_v6'; state = $(if ($script:aReads -ge 3) { 'RESERVING' } else { 'QUOTA_VERIFIED' }) }
        } -ParameterFilter { $RelPath -eq 'capacity/wave-1-a-d4ds.json' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -like '*got a capacity reservation*' } { throw 'The store did not answer.' }
        $r = Set-VmfWavePlan -RunPath $script:rp -PlanPath (Join-Path $script:rp 'plan.json') -ChangedBy 'operator@example.com' -Confirm:$false -Layout $script:wrLayout -WarningAction SilentlyContinue
        @($r.CapacityChecksCleared) | Should -Be @('wave-1')
        Test-Path (Join-Path $script:rp 'capacity' 'wave-1-d2ds.json') | Should -BeFalse -Because 'the other quota check of the wave no longer matches it'
        Test-Path (Join-Path $script:rp 'capacity' 'wave-1-a-d4ds.json') | Should -BeTrue -Because 'a record that bills is never removed'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' -and $Detail -like '*got a capacity reservation*' } -Times 1 -Exactly
    }

    It 'the line that says the quota check was removed cannot be written: the save is returned, with its own line' {
        $script:rp = WrRun 'QUOTA_VERIFIED'
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' } { throw 'The store did not answer.' }
        $r = Set-VmfWavePlan -RunPath $script:rp -PlanPath (Join-Path $script:rp 'plan.json') -ChangedBy 'operator@example.com' -Confirm:$false -Layout $script:wrLayout -WarningAction SilentlyContinue
        @($r.CapacityChecksCleared) | Should -Be @('wave-1')
        $ev = InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp } { Read-VmfEvents -RunPath $p -Step 'plan' }
        @($ev | Where-Object { $_.detail -like 'wave layout changed by operator@example.com*' }).Count | Should -Be 1
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' } -Times 1 -Exactly
    }

    It 'the save line cannot be written: the save is returned, and the list is told' {
        $script:rp = WrRun 'QUOTA_VERIFIED'
        Mock -ModuleName VmMigrationFactory Update-VmfRunSummary { $true }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'plan' } { throw 'The store did not answer.' }
        $r = Set-VmfWavePlan -RunPath $script:rp -PlanPath (Join-Path $script:rp 'plan.json') -ChangedBy 'operator@example.com' -Confirm:$false -Layout $script:wrLayout -WarningVariable w -WarningAction SilentlyContinue
        @($r.CapacityChecksCleared) | Should -Be @('wave-1')
        ((Get-Content (Join-Path $script:rp 'plan.json') -Raw | ConvertFrom-Json -Depth 24).entries | Where-Object vmId -eq $script:vm1).policy.onDDataFound | Should -Be 'proceed'
        (@($w | ForEach-Object { [string]$_ }) -join ' ') | Should -BeLike "*'plan ok' could not be written*"
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -ParameterFilter { $Reason -eq 'planSaved' } -Times 1 -Exactly
    }
}

Describe 'WAVE-EDIT-RESERVE-1: nothing is removed when any claim of the wave bills' {
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'a quota check and a reservation in one wave: the save refuses and BOTH records stay' {
        # Independent review: a refusal partway through removal left the
        # records judged before it removed, and the plan unsaved.
        $script:rp = WrRun 'QUOTA_VERIFIED'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/wave-1-zz-d4ds.json' -Depth 12 -Document ([ordered]@{
                schemaVersion = 8; wave = 'wave-1'; region = 'centralus'; size = 'Standard_D4ds_v6'; count = 1; state = 'RESERVED' })
        }
        { WrSave $script:rp } | Should -Throw '400: Wave wave-1 has an on-demand capacity reservation in Azure (RESERVED)*'
        Test-Path (Join-Path $script:rp 'capacity' 'wave-1-d2ds.json') | Should -BeTrue -Because 'judged before anything was removed'
        Test-Path (Join-Path $script:rp 'capacity' 'wave-1-zz-d4ds.json') | Should -BeTrue
    }

    It 'the log line keeps the dates as ISO UTC, not as a re-read date value' {
        # ConvertFrom-Json turns an ISO date into a date value, and [string] of
        # that is month-first with no zone (CLAUDE.md).
        $script:rp = WrRun 'RELEASED'
        WrSave $script:rp | Out-Null
        $ev = InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp } { Read-VmfEvents -RunPath $p -Step 'capacity' }
        $line = @($ev | Where-Object { $_.detail -match 'released on-demand capacity reservation' })[0].detail
        $line | Should -Match 'reserved 2026-09-20T10:00:00Z and released 2026-09-21T10:00:00Z'
    }
}

Describe 'WAVE-EDIT-RESERVE-1: the engine refuses a release under machines that may be using it' {
    BeforeEach {
        $script:rp = WrRun 'RESERVED'
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'no machine touched yet: the release may run' {
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp } { Get-VmfWaveReleaseRefusal -RunPath $p -Wave 'wave-1' | Should -BeNullOrEmpty }
    }

    It 'a machine taken by a worker reads PLANNED, and that counts' {
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp; id = $script:vm1 } {
            New-VmfStateDoc -RunPath $p -RunId 'wr-test' -VmId $id -Wave 'wave-1' | Out-Null
            Get-VmfWaveReleaseRefusal -RunPath $p -Wave 'wave-1' | Should -Match 'vm1 is PLANNED'
        }
    }

    It 'a lease counts, before any state is written' {
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp; id = $script:vm1 } {
            Write-VmfStoreJson -RunPath $p -RelPath (Get-VmfLeaseRelPath -VmId $id) -Document @{ vmId = $id; workerId = 'worker-1' } -Depth 4
            Get-VmfWaveReleaseRefusal -RunPath $p -Wave 'wave-1' | Should -Match 'vm1 is held by a worker'
        }
    }

    It 'a machine parked on a decision, or finished, does not stop it - that is the operator''s call' {
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp; id = $script:vm1 } {
            $doc = New-VmfStateDoc -RunPath $p -RunId 'wr-test' -VmId $id -Wave 'wave-1'
            $doc.state = 'NEEDS_DECISION'
            Write-VmfStateDoc -RunPath $p -Document $doc | Out-Null
            Get-VmfWaveReleaseRefusal -RunPath $p -Wave 'wave-1' | Should -BeNullOrEmpty
        }
    }

    It 'the engine''s release operation asks it before it releases anything' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1')
        $branch = $code.Substring($code.IndexOf("'release' {"))
        $ask = $branch.IndexOf('Get-VmfWaveReleaseRefusal')
        $ask | Should -BeGreaterThan 0
        $ask | Should -BeLessThan $branch.IndexOf('Remove-VmfCapacityReservations')
    }
}

Describe 'WAVE-EDIT-RESERVE-1: after a release, checking the quota of that wave is the way back' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wq-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:runPath -Force | Out-Null
        $sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines'
        @{ schemaVersion = 1; assessmentRunId = 'r1'; entries = @(
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/a"; wave = 'wave-1'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2ds_v6' } },
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/b"; wave = 'wave-2'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2ds_v6' } })
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'plan.json')
        $script:planPath = Join-Path $script:runPath 'plan.json'
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @([pscustomobject]@{ Name = 'Standard_D2ds_v6'; ResourceType = 'virtualMachines'; Family = 'StandardDdsv6Family'; Restrictions = @()
                Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = '2' }, [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }) })
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDdsv6Family' }; CurrentValue = 0; Limit = 10 })
        }
        Mock -ModuleName VmMigrationFactory Get-VmfRetailPrice { $null }
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath | Out-Null
        foreach ($w in 'wave-1', 'wave-2') {
            $file = Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter "$w-*.json" | Select-Object -First 1
            $doc = Get-Content $file.FullName -Raw | ConvertFrom-Json
            $doc.state = 'RELEASED'
            $doc | ConvertTo-Json -Depth 12 | Set-Content $file.FullName
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'a check of that wave replaces its released record, so the wave can start and be reserved again' {
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath -Wave 'wave-1' | Out-Null
        $w1 = Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter 'wave-1-*.json' | Select-Object -First 1
        (Get-Content $w1.FullName -Raw | ConvertFrom-Json).state | Should -Be 'QUOTA_VERIFIED'
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1').Pass | Should -BeTrue
        $w2 = Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter 'wave-2-*.json' | Select-Object -First 1
        (Get-Content $w2.FullName -Raw | ConvertFrom-Json).state | Should -Be 'RELEASED' -Because 'another wave is not touched'
    }

    It 'a check of EVERY wave - the one a wave start runs - keeps each released record as history' {
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath | Out-Null
        foreach ($w in 'wave-1', 'wave-2') {
            $f = Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter "$w-*.json" | Select-Object -First 1
            (Get-Content $f.FullName -Raw | ConvertFrom-Json).state | Should -Be 'RELEASED'
        }
    }
}

Describe 'WAVE-EDIT-RESERVE-1: one rule for both writers' {
    It 'Set-VmfWavePlan and Set-VmfMachineTarget ask the same function which claims bill' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        foreach ($f in 'Set-VmfWavePlan.ps1', 'Set-VmfMachineTarget.ps1') {
            $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' $f)
            $code | Should -Match 'Get-VmfBillingClaimRefusal' -Because "$f must use the shared rule"
        }
    }

    It 'a released record no longer stops a target change: it is cleared with a log line' {
        InModuleScope VmMigrationFactory {
            Get-VmfBillingClaimRefusal -Wave 'w' -States @('RELEASED') -Action 'change it' | Should -BeNullOrEmpty
            Get-VmfBillingClaimRefusal -Wave 'w' -States @('QUOTA_VERIFIED', 'RESERVED') -Action 'change it' | Should -Match 'RESERVED'
        }
    }
}
