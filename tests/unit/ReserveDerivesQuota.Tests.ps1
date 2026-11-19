#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RESERVE-QUOTA-1, 2026-09-21. Found by trying to use the product.
#
# THE RESERVE CAPACITY CONTROL COULD NOT WORK. Not on this install, not on any
# install, not in any order.
#
# Reserving reads records that say what a wave needs and what Azure's quota
# allows. Those records are written when a wave is PLANNED. But changing a wave
# clears them - correctly, because they describe the wave as it was:
#
#   "wave layout changed ... quota check cleared for wave-1"
#   "quota checks cleared - they described the waves as they were, and
#    capacity is checked again before a wave starts"
#
# AND CHOOSING "RESERVED CAPACITY" IS A CHANGE TO THE WAVE. So picking the
# setting was itself the act that destroyed the records reserving needs. The
# promised re-check happens before a wave STARTS, which is after reserving and
# never before it.
#
# So the button threw "No quota records - run Test-VmfQuota first"
# - naming a command the dashboard cannot run, for a step that reserves nothing
# and spends nothing.
#
# The engine already names this exact antipattern elsewhere: "demanding that a
# person run it by hand, from a dashboard that cannot run it, is a workflow gap
# rather than a safety gate."
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
}

Describe 'RESERVE-QUOTA-1: reserving derives what it needs' {

    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rq-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'rq-test' | Out-Null
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'with NO records, it checks quota rather than refusing' {
        # The whole defect, in one case. Before this, the wave a person had
        # just set to reserved had no records - and got a refusal.
        $made = $false
        Mock -ModuleName VmMigrationFactory Test-VmfQuota {
            $script:forecastRan = $true
            $dir = Join-Path $OutPath 'capacity'
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            ([ordered]@{
                schemaVersion = 7; runId = 'rq-test'; wave = 'prod-1'
                subscriptionId = '00000000-0000-0000-0000-000000000000'; resourceGroup = 'rg-app'
                region = 'centralus'; zone = $null; size = 'Standard_D2s_v6'
                vmFamily = 'StandardDsv6Family'; state = 'QUOTA_VERIFIED'; blockReason = $null
                demand = @{ instances = 2; reservableInstances = 2; vcpus = 4; overlapWithSource = $false }
                quota = @{ limit = 10; used = 0; requestId = $null; requestedUtc = $null }
                notes = @()
            } | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $dir 'derived.json')
        }
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
            $made = $true
            @{ GroupId = '/subs/s/rg/crg/g1'; ReservationId = '/subs/s/rg/crg/g1/res/r1' }
        }
        $script:forecastRan = $false

        $r = New-VmfWaveReservation -OutPath $script:runPath -Wave 'prod-1'

        $script:forecastRan | Should -BeTrue -Because 'it must derive the records rather than refuse'
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 1 `
            -Because 'and then actually reserve, which is what the button is for'
        @($r).Count | Should -BeGreaterThan 0
    }

    It 'and it never names a command the dashboard cannot run' {
        # Four messages in two days sent an operator to PowerShell. This one
        # blocked a whole feature.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $src = Get-VmfCodeOnly -Path (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'Public' 'New-VmfWaveReservation.ps1')
        $src | Should -Not -Match 'run Test-VmfQuota first'
        $src | Should -Not -Match 'No quota records - run'
    }

    It 'with records ALREADY there, it does not check again' {
        # Deriving is free but not instant - it reads the SKU catalogue and
        # quota usage per cell. A wave that has been planned and not changed
        # already has its answers.
        $dir = Join-Path $script:runPath 'capacity'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        ([ordered]@{
            schemaVersion = 7; runId = 'rq-test'; wave = 'prod-1'
            subscriptionId = '00000000-0000-0000-0000-000000000000'; resourceGroup = 'rg-app'
            region = 'centralus'; zone = $null; size = 'Standard_D2s_v6'
            vmFamily = 'StandardDsv6Family'; state = 'QUOTA_VERIFIED'; blockReason = $null
            demand = @{ instances = 1; reservableInstances = 1; vcpus = 2; overlapWithSource = $false }
            quota = @{ limit = 10; used = 0; requestId = $null; requestedUtc = $null }
            notes = @()
        } | ConvertTo-Json -Depth 8) | Set-Content (Join-Path $dir 'existing.json')

        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation {
            @{ GroupId = '/g'; ReservationId = '/g/r' }
        }
        New-VmfWaveReservation -OutPath $script:runPath -Wave 'prod-1' | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfQuota -Times 0 `
            -Because 'the answers are already there'
    }

    It 'and a plan that yields nothing says so, without naming a cmdlet' {
        # The honest end of the road: the derivation ran and produced nothing,
        # so there is genuinely nothing to reserve. It says WHY.
        Mock -ModuleName VmMigrationFactory Test-VmfQuota { }
        Mock -ModuleName VmMigrationFactory New-VmfCapacityReservation { @{ GroupId = '/g'; ReservationId = '/g/r' } }
        { New-VmfWaveReservation -OutPath $script:runPath -Wave 'prod-1' } |
            Should -Throw -ExpectedMessage '*nothing*to reserve*'
        Should -Invoke -ModuleName VmMigrationFactory New-VmfCapacityReservation -Times 0 `
            -Because 'nothing is reserved when there is nothing to reserve'
    }

    It 'the derivation is announced, and says it spends nothing' {
        # A person watching a run should see why a step they did not ask for
        # is happening - and that it is free.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $src = Get-VmfCodeOnly -Path (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'Public' 'New-VmfWaveReservation.ps1')
        $src | Should -Match 'This check reserves nothing and costs nothing'
        $src | Should -Match "Write-VmfStepLine -RunPath \`$OutPath -Step 'capacity' -Outcome info"
    }
}
