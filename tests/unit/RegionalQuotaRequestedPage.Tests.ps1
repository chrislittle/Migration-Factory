#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REGIONAL-QUOTA-REQUESTED-PAGE-1, 2026-11-07.
#
# After Request an increase filed a Total Regional vCPUs request, the migration
# page showed the regional row as Headroom verified with the old usage while
# the request waited: the record is QUOTA_REQUESTED, not blocked, and the card
# read only "blocked". The page now asks help.js claimRegionalRequested, held
# to tests/fixtures/regional-requested.json.
#
# The engine has no reader of that question, so it has no twin. What holds the
# page to the engine is the fixture: each case with an 'engine' name is the
# record Request-VmfQuota writes in that situation. This file runs each
# situation and checks the record the engine writes against its case, so a
# change to what the engine writes fails here, and tests/js/regional-quota.test.js
# fails a change to what the page reads.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:cases = (Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'regional-requested.json') -Raw |
        ConvertFrom-Json -Depth 12).cases

    # A record as Test-VmfQuota writes it (capacity-claim v14), through the
    # module's own builder.
    function Global:RqClaim {
        param([string]$RunPath, [string]$Reason, [bool]$RegionalShort, $QuotaLimit = 10, $QuotaUsed = 8,
              $RegionalLimit = 10, $RegionalUsed = 8)
        InModuleScope VmMigrationFactory -Parameters @{ d = @{
                RunPath = $RunPath; Reason = $Reason; RegionalShort = $RegionalShort; QuotaLimit = $QuotaLimit
                QuotaUsed = $QuotaUsed; RegionalLimit = $RegionalLimit; RegionalUsed = $RegionalUsed } } {
            param($d)
            Initialize-VmfStore -RunPath $d.RunPath
            $claim = New-VmfCapacityClaim -RunId 'r1' -Wave 'wave-1' -SubscriptionId '00000000-0000-0000-0000-000000000000' -ResourceGroup 'rg-app' `
                -Region 'centralus' -Size 'Standard_D4s_v6' -VmFamily 'standardDSv6Family' -State 'BLOCKED' -BlockReason $d.Reason `
                -Instances 1 -ReservableInstances 1 -Vcpus 4 -FamilyVcpus 4 `
                -QuotaLimit $d.QuotaLimit -QuotaUsed $d.QuotaUsed -RegionalVcpus 6 -RegionalAdds 4 -RegionalShort $d.RegionalShort `
                -RegionalLimit $d.RegionalLimit -RegionalUsed $d.RegionalUsed -RequestAccess 'granted' -CheckedUtc '2026-11-06T10:00:00.0000000Z'
            Write-VmfStoreJson -RunPath $d.RunPath -RelPath 'capacity/c1.json' -Document $claim -Depth 12
        }
    }
}
AfterAll {
    Remove-Item 'function:\RqClaim' -ErrorAction SilentlyContinue
}

Describe 'REGIONAL-QUOTA-REQUESTED-PAGE-1: the records Request-VmfQuota writes are the cases the page is held to' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rq-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:rp -Force | Out-Null
        # What Azure answers for each quota: 202 a request that waits (with
        # its id), 200 approved at once (no id), 400 refused.
        $script:answer = @{}
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease {
            $code = if ($script:answer.ContainsKey($Family)) { $script:answer[$Family] } else { 202 }
            switch ($code) {
                200 { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
                400 { [pscustomobject]@{ StatusCode = 400; Content = '{"error":{"code":"BadRequest","message":"refused"}}' } }
                default { [pscustomobject]@{ StatusCode = 202; Content = ('{"id":"/quota-requests/' + $Family + '"}') } }
            }
        }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'the fixture names every situation this file runs' {
        foreach ($name in 'regional-own-pending', 'regional-own-approved', 'both-pending', 'both-approved',
                          'family-refused-region-filed', 'region-refused-family-filed', 'family-only') {
            @($script:cases | Where-Object { $_.PSObject.Properties['engine'] -and $_.engine -eq $name }).Count |
                Should -Be 1 -Because "the case '$name'"
        }
    }

    It 'the engine writes the record of <Name>' -ForEach @(
        @{ Name = 'regional-own-pending'; Reason = 'regional-quota-shortfall'; Short = $true; FamilyLimit = 100; Answer = @{ cores = 202 } }
        @{ Name = 'regional-own-approved'; Reason = 'regional-quota-shortfall'; Short = $true; FamilyLimit = 100; Answer = @{ cores = 200 } }
        @{ Name = 'both-pending'; Reason = 'quota-shortfall'; Short = $true; FamilyLimit = 10; Answer = @{ cores = 202; standardDSv6Family = 202 } }
        @{ Name = 'both-approved'; Reason = 'quota-shortfall'; Short = $true; FamilyLimit = 10; Answer = @{ cores = 200; standardDSv6Family = 200 } }
        @{ Name = 'family-refused-region-filed'; Reason = 'quota-shortfall'; Short = $true; FamilyLimit = 10; Answer = @{ cores = 202; standardDSv6Family = 400 } }
        @{ Name = 'region-refused-family-filed'; Reason = 'quota-shortfall'; Short = $true; FamilyLimit = 10; Answer = @{ cores = 400; standardDSv6Family = 202 } }
        @{ Name = 'family-only'; Reason = 'quota-shortfall'; Short = $false; FamilyLimit = 10; Answer = @{ standardDSv6Family = 202 } }
    ) {
        $script:answer = $Answer
        $regionalLimit = if ($Short) { 10 } else { 100 }
        $regionalUsed = if ($Short) { 8 } else { 0 }
        RqClaim -RunPath $script:rp -Reason $Reason -RegionalShort $Short -QuotaLimit $FamilyLimit -QuotaUsed 8 `
            -RegionalLimit $regionalLimit -RegionalUsed $regionalUsed
        Request-VmfQuota -OutPath $script:rp | Out-Null

        $wrote = Get-Content (Join-Path $script:rp 'capacity' 'c1.json') -Raw | ConvertFrom-Json -Depth 12
        $case = @($script:cases | Where-Object { $_.PSObject.Properties['engine'] -and $_.engine -eq $Name })[0].claim
        $wrote.state | Should -Be $case.state
        $wrote.blockReason | Should -Be $case.blockReason
        $wrote.regionalShort | Should -Be $case.regionalShort
        # A request id is compared as it is; a time only by whether it is there.
        foreach ($field in 'requestId', 'regionalRequestId') {
            [string]$wrote.quota.$field | Should -Be ([string]$case.quota.$field) -Because "quota.$field of $Name"
        }
        foreach ($field in 'requestedUtc', 'regionalRequestedUtc') {
            [bool][string]$wrote.quota.$field | Should -Be ([bool][string]$case.quota.$field) -Because "quota.$field of $Name"
        }
    }
}
