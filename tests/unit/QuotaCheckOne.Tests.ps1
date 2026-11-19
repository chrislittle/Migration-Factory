#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
QUOTA-BUTTON-1: "Check the quota" asked nobody.

The wave editor's button called only the READ of the wave's stored quota
records - and saving the waves clears those records, because they described the
waves as they were. So on a plan somebody had just arranged, the button found no
records and said "The quota is not enough", in red, in about a second.

The fix asks Azure: a `quotacheck` engine operation runs Test-VmfQuota for ONE
wave. And building it found a worse defect underneath: Test-VmfQuota rewrote
every record for the plan unconditionally, including one that stood for a
capacity reservation in Azure - and Start-VmfWave re-runs the whole check when
one wave has no records. So starting a wave could erase the only record of
another wave's paid reservation, which then billed with nothing pointing at it.
#>
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:QcSku {
        param([string]$Name, [string]$Family)
        [pscustomobject]@{
            Name = $Name; ResourceType = 'virtualMachines'; Family = $Family; Restrictions = @()
            Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = '2' },
                             [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' })
        }
    }
    function Global:QcOperator {
        $claims = @(@{ typ = 'preferred_username'; val = 'oper@example.com' }, @{ typ = 'roles'; val = 'Vmf.Operator' })
        $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
        ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
    }
}
AfterAll { Remove-Item 'function:\QcSku', 'function:\QcOperator' -ErrorAction SilentlyContinue }

Describe 'QUOTA-BUTTON-1: a quota check for one wave' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-qc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:runPath -Force | Out-Null
        $sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines'
        @{ schemaVersion = 1; assessmentRunId = 'r1'; entries = @(
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/a"; wave = 'wave-1'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2ds_v6' } },
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/b"; wave = 'wave-2'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2ds_v6' } })
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'plan.json')
        $script:planPath = Join-Path $script:runPath 'plan.json'
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(QcSku 'Standard_D2ds_v6' 'StandardDdsv6Family') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'StandardDdsv6Family' }; CurrentValue = 0; Limit = 10 })
        }
        Mock -ModuleName VmMigrationFactory Get-VmfRetailPrice { $null }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'writes only the wave it was asked about' {
        $r = Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath -Wave 'wave-2'
        @($r.Claims).Count | Should -Be 1
        @($r.Claims)[0].wave | Should -Be 'wave-2'
        @(Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter '*.json').Count | Should -Be 1
        (@(Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter '*.json')[0].Name) | Should -Match '^wave-2-'
    }

    It 'names its wave, and what the saved plan holds in it, in the line the page waits for' {
        # QUOTA-TRUTH-1: two checks started together each took the first
        # "claims=" line, and a zero could not be told from a wave the saved
        # plan did not have yet.
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath -Wave 'wave-2' | Out-Null
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath -Wave 'not-saved-yet' | Out-Null
        $lines = @(Get-Content (Join-Path $script:runPath 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object step -EQ 'capacity')
        $lines[-2].detail | Should -Be 'claims=1 blocked=0 wave=wave-2 machines=1 moving=1'
        $lines[-1].detail | Should -Be 'claims=0 blocked=0 wave=not-saved-yet machines=0 moving=0'
    }

    It 'and the gate the button reads then answers from a real check' {
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath -Wave 'wave-1' | Out-Null
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-1').Pass | Should -BeTrue
        (Test-VmfQuotaAndReservation -OutPath $script:runPath -Wave 'wave-2').Detail | Should -Match 'no quota records' `
            -Because 'the other wave was not checked, and says so rather than failing'
    }

    It 'never overwrites a record that stands for a reservation in Azure' {
        # The worse defect: a whole-plan check (what Start-VmfWave runs when ONE
        # wave has no records) replaced every other wave's record, reservation
        # included.
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath | Out-Null
        $file = Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter 'wave-2-*.json' | Select-Object -First 1
        foreach ($held in 'RESERVING', 'RESERVED', 'CONSUMED', 'RELEASED') {
            $doc = Get-Content $file.FullName -Raw | ConvertFrom-Json
            $doc.state = $held
            $doc | Add-Member -NotePropertyName reservation -NotePropertyValue ([pscustomobject]@{ groupId = '/x/crg'; reservationId = '/x/crg/r1' }) -Force
            $doc | ConvertTo-Json -Depth 12 | Set-Content $file.FullName
            Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath | Out-Null
            $after = Get-Content $file.FullName -Raw | ConvertFrom-Json
            $after.state | Should -Be $held -Because "a $held record describes something in Azure"
            $after.reservation.reservationId | Should -Be '/x/crg/r1'
        }
    }

    It 'but DOES re-check a record that only asked for more quota' {
        # QUOTA_REQUESTED is exactly the case a re-check exists for - Request-VmfQuota
        # says to re-run this to see whether the increase landed.
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath | Out-Null
        $file = Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter 'wave-2-*.json' | Select-Object -First 1
        $doc = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $doc.state = 'QUOTA_REQUESTED'
        $doc | ConvertTo-Json -Depth 12 | Set-Content $file.FullName
        Test-VmfQuota -PlanPath $script:planPath -OutPath $script:runPath | Out-Null
        (Get-Content $file.FullName -Raw | ConvertFrom-Json).state | Should -Be 'QUOTA_VERIFIED'
    }
}

Describe 'QUOTA-BUTTON-1: the app can start it' {
    It 'the service accepts quotacheck, from an operator, and insists on a wave' {
        { Invoke-VmfFacadeStartEngine -Principal (QcOperator) -Operation 'quotacheck' -RunId 'r1' } |
            Should -Throw '400: checking the quota requires a wave name'
    }

    It 'the engine runs the check for that wave and nothing else' {
        $entry = Get-Content (Join-Path $PSScriptRoot '..' '..' 'docker' 'entrypoint.ps1') -Raw
        $branch = [regex]::Match($entry, "(?s)'quotacheck' \{(.*?)\n    \}").Groups[1].Value
        $branch | Should -Match 'Test-VmfQuota -PlanPath "\$runPath/plan\.json" -OutPath \$runPath -Wave \$env:VMF_WAVE'
        $branch | Should -Match 'VMF_WAVE is required'
    }
}
