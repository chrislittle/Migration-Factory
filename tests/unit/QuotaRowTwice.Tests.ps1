#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
QUOTA-ROW-TWICE-1: one quota check is ONE reading, so its records carry ONE time.

The Migrations page shows, for a quota family in a region, the reading of the
NEWEST quota check (newestCheckOf in src/dashboard/migrations.js), and finds
the records of that check by their quota.checkedUtc. Test-VmfQuota wrote the
time of EACH record as it built it, milliseconds apart, so the records of one
check of several sizes looked like several checks, and the page could show one
record of the newest check and hide another.
#>
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:QrtSku {
        param([string]$Name, [string]$Family)
        [pscustomobject]@{
            Name = $Name; ResourceType = 'virtualMachines'; Family = $Family; Restrictions = @()
            Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = '2' },
                             [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' })
        }
    }
}
AfterAll { Remove-Item 'function:\QrtSku' -ErrorAction SilentlyContinue }

Describe 'QUOTA-ROW-TWICE-1: the records of one quota check share one checkedUtc' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-qrt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:runPath -Force | Out-Null
        $sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines'
        @{ schemaVersion = 1; assessmentRunId = 'r1'; entries = @(
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/a"; wave = 'wave-1'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2ds_v5' } },
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/b"; wave = 'wave-2'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2ds_v5' } },
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/c"; wave = 'wave-2'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D4ds_v5' } },
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/d"; wave = 'wave-3'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2ds_v5'; zone = '2' } })
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'plan.json')
        $script:planPath = Join-Path $script:runPath 'plan.json'
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @((QrtSku 'Standard_D2ds_v5' 'standardDDSv5Family'), (QrtSku 'Standard_D4ds_v5' 'standardDDSv5Family'))
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardDDSv5Family' }; CurrentValue = 0; Limit = 20 })
        }
        # Each record takes a moment to build (a price lookup is a call to
        # Azure), so a time taken per record differs between records.
        Mock -ModuleName VmMigrationFactory Get-VmfRetailPrice {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while ($sw.ElapsedMilliseconds -lt 15) { }
            $null
        }
        Mock -ModuleName VmMigrationFactory Get-VmfZoneRestrictionCode { $null }
        Mock -ModuleName VmMigrationFactory Test-VmfSizeInZone { $true }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'stamps one time on every record of a check of every wave' {
        $r = Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath
        @($r.Claims).Count | Should -Be 4 -Because 'four cells: wave, size and zone'
        $times = @($r.Claims | ForEach-Object { [string]$_.quota.checkedUtc } | Sort-Object -Unique)
        $times.Count | Should -Be 1 -Because "one check is one reading, got: $($times -join ', ')"
        $stored = @(Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter '*.json' |
            ForEach-Object { [string]((Get-Content $_.FullName -Raw | ConvertFrom-Json -DateKind String).quota.checkedUtc) } | Sort-Object -Unique)
        $stored.Count | Should -Be 1 -Because 'the stored records say the same'
    }

    It 'and a later check of one wave has a later time, which the other waves keep the older one of' {
        $first = Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath
        $t1 = [string]@($first.Claims)[0].quota.checkedUtc
        $second = Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath -Wave 'wave-2'
        $t2 = @($second.Claims | ForEach-Object { [string]$_.quota.checkedUtc } | Sort-Object -Unique)
        $t2.Count | Should -Be 1 -Because 'the two records of wave-2 are one check'
        ([datetimeoffset]::Parse($t2[0]) -gt [datetimeoffset]::Parse($t1)) | Should -BeTrue
        $wave1 = Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter 'wave-1-*.json' | Select-Object -First 1
        [string]((Get-Content $wave1.FullName -Raw | ConvertFrom-Json -DateKind String).quota.checkedUtc) | Should -Be $t1
    }
}