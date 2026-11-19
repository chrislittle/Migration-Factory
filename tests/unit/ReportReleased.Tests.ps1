#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REPORT-RELEASED-1: a released reservation stays in the report after its
# record is cleared.
#
# A RELEASED claim is cleared when its wave changes, when one machine's target
# changes, or when the wave's quota is checked again - kept, it would stop the
# wave starting. The activity log said what it recorded, but neither report
# reads the log, so billed reservation time disappeared from the customer
# report and the Reports page. Now the claim is kept under capacity-history/
# (schemas/capacity-history.schema.json), one file per reservation, and both
# reports read it beside the live claims.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:historySchema = Join-Path $script:repoRoot 'schemas' 'capacity-history.schema.json'
    function Global:RrClaim([string]$ReservationId = '/rg/crg/g1/capacityReservations/r1', [int]$Consumed = 2) {
        [pscustomobject]@{
            schemaVersion = 8; runId = 'rr'; wave = 'w1'; subscriptionId = '00000000-0000-0000-0000-000000000000'
            region = 'centralus'; zone = $null
            size = 'Standard_D4ds_v6'; vmFamily = 'StandardDdsv6Family'; state = 'RELEASED'; blockReason = $null
            demand = [pscustomobject]@{ instances = 2; reservableInstances = 2; vcpus = 8; overlapWithSource = $false }
            quota = [pscustomobject]@{ limit = 10; used = 0; requestId = $null; requestedUtc = $null }
            reservation = [pscustomobject]@{ groupId = 'g'; reservationId = $ReservationId; createdUtc = [datetime]'2026-11-01T14:00:00Z'
                releasedUtc = '2026-11-02T03:00:00Z'; consumedInstances = $Consumed }
            associatedVmIds = @(); notes = @()
        }
    }
    function Global:RrHistory($rp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
            @(Get-VmfStoreNames -RunPath $rp -Folder 'capacity-history' -Extension '.json' | ForEach-Object { Read-VmfStoreJson -RunPath $rp -RelPath "capacity-history/$_" -Depth 14 })
        }
    }
}
AfterAll { Remove-Item 'function:\RrClaim', 'function:\RrHistory' -ErrorAction SilentlyContinue }

Describe 'REPORT-RELEASED-1: a released claim is kept as history before it is cleared' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'rr' | Out-Null }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'the note keeps the claim, with when and why it was cleared, in its own contract' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; c = (Global:RrClaim) } {
            Write-VmfReleasedClaimNote -RunPath $rp -Claim $c -Because checked
        }
        $h = @(RrHistory $script:rp)
        $h.Count | Should -Be 1
        $h[0].because | Should -Be 'checked'
        $h[0].claim.state | Should -Be 'RELEASED'
        $h[0].claim.reservation.consumedInstances | Should -Be 2
        $file = @(Get-ChildItem (Join-Path $script:rp 'capacity-history') -Filter '*.json')[0].FullName
        { Test-Json -Json (Get-Content $file -Raw) -SchemaFile $script:historySchema -ErrorAction Stop } | Should -Not -Throw
    }

    It 'one file per reservation: a second write of the same one replaces the first' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; c = (Global:RrClaim) } {
            Save-VmfReleasedClaimHistory -RunPath $rp -Claim $c
            Write-VmfReleasedClaimNote -RunPath $rp -Claim $c
        }
        @(RrHistory $script:rp).Count | Should -Be 1
    }

    It 'two reservations of one wave keep two records' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; a = (Global:RrClaim '/r/1'); b = (Global:RrClaim '/r/2') } {
            Write-VmfReleasedClaimNote -RunPath $rp -Claim $a
            Write-VmfReleasedClaimNote -RunPath $rp -Claim $b
        }
        @(RrHistory $script:rp).Count | Should -Be 2
    }

    It 'history is never read as a live claim, on blob storage either: folder listings end with a slash' {
        $script:uris = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest { $script:uris.Add($Uri); [pscustomobject]@{ StatusCode = 200; Content = '<EnumerationResults><Blobs></Blobs></EnumerationResults>'; Headers = @{} } }
        InModuleScope VmMigrationFactory { Get-VmfStoreNames -RunPath 'azblob://acct/cont/run-1' -Folder 'capacity' -Extension '.json' | Out-Null }
        $script:uris.Count | Should -BeGreaterThan 0
        $script:uris[0] | Should -Match 'prefix=run-1(/|%2F)capacity(/|%2F)(&|$)' -Because "a prefix of 'capacity' without the slash would also list capacity-history"
    }

    It 'every writer that clears a released claim keeps it first' -ForEach @(
        @{ File = 'Public/Set-VmfWavePlan.ps1' }, @{ File = 'Public/Test-VmfQuota.ps1' }, @{ File = 'Public/Set-VmfMachineTarget.ps1' }) {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' $File)
        $code | Should -Match 'Write-VmfReleasedClaimNote|Save-VmfReleasedClaimHistory'
    }

    It 'a target change keeps it BEFORE it takes the claim' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Set-VmfMachineTarget.ps1')
        $code.IndexOf('Save-VmfReleasedClaimHistory') | Should -BeLessThan $code.IndexOf('& $take "capacity/')
        $code.IndexOf('Save-VmfReleasedClaimHistory') | Should -BeGreaterThan 0
    }
}

Describe 'REPORT-RELEASED-1: the customer report' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:rp 'state') -Force | Out-Null
        @{ schemaVersion = 1; assessmentRunId = 'rr'; entries = @(
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/app-1'; wave = 'w1'; path = 'A'; assessment = @{ sourceSize = 'Standard_D4ds_v4'; location = 'centralus' }
                   target = @{ size = 'Standard_D4ds_v6'; controller = 'NVMe' }; planNotes = @() }) } |
            ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:rp 'plan.json')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; c = (Global:RrClaim) } {
            Write-VmfReleasedClaimNote -RunPath $rp -Claim $c
        }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'the capacity table shows the released reservation whose record was cleared, in ISO UTC' {
        $html = Get-Content (New-VmfReport -OutPath $script:rp) -Raw
        $html | Should -Match 'Capacity and cost'
        $html | Should -Match '<td>2026-11-01T14:00:00Z &rarr; 2026-11-02T03:00:00Z</td>'
        # MANUAL-REVIEW-1: the column in Azure's name.
        $html | Should -Match '<th>Used</th><th>Capacity reservation window</th><th>State</th>'
    }

    It 'a reservation a live claim still shows is not shown twice' {
        New-Item -ItemType Directory -Path (Join-Path $script:rp 'capacity') -Force | Out-Null
        (Global:RrClaim) | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:rp 'capacity' 'c1.json')
        $html = Get-Content (New-VmfReport -OutPath $script:rp) -Raw
        ([regex]::Matches($html, '2026-11-01T14:00:00Z &rarr;')).Count | Should -Be 1
    }

    It 'the commercial review names only the families of the live claims' {
        $html = Get-Content (New-VmfReport -OutPath $script:rp) -Raw
        $html | Should -Not -Match 'quota families <em>'
    }

    # MANUAL-REVIEW-1: the Costs line in Azure's names. An Azure Reservation
    # covers only the sizes of its own instance size flexibility group; an Azure
    # savings plan for compute covers the new size too.
    It 'a reservation not released yet says so in its window, and that it is billed' {
        New-Item -ItemType Directory -Path (Join-Path $script:rp 'capacity') -Force | Out-Null
        $c = Global:RrClaim '/rg/crg/g1/capacityReservations/r2'
        $c.state = 'RESERVED'; $c.reservation.releasedUtc = $null
        $c | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:rp 'capacity' 'c2.json')
        $html = Get-Content (New-VmfReport -OutPath $script:rp) -Raw
        $html | Should -Match '<td>2026-11-01T14:00:00Z &rarr; Not released yet, and billed until it is</td>'
    }

    It 'a live claim gives the Costs line, in Azure''s names' {
        New-Item -ItemType Directory -Path (Join-Path $script:rp 'capacity') -Force | Out-Null
        (Global:RrClaim) | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:rp 'capacity' 'c1.json')
        $html = Get-Content (New-VmfReport -OutPath $script:rp) -Raw
        $html | Should -Match ([regex]::Escape('<p><strong>Costs:</strong> The target sizes are in the quota families <em>StandardDdsv6Family</em>. An Azure Reservation covers only the sizes of its own instance size flexibility group. So a reservation for the old size does not cover the new size. An Azure savings plan for compute covers the new size too.</p>'))
        $html | Should -Not -Match 'family-scoped|Commercial review'
    }

    It 'the quota records list only live claims - a history record is not a quota check' {
        $html = Get-Content (New-VmfReport -OutPath $script:rp) -Raw
        $html | Should -Not -Match '<h2>Quota records</h2>'
    }

    It 'a restored machine''s time is never month-first' {
        @{ schemaVersion = (Get-VmfTestStateVersion); runId = 'rr'; vmId = '/s/rg/vm/app-1'; state = 'MIGRATED'; history = @()
           restore = @{ restoredUtc = '2026-11-03T10:00:00Z'; restoredBy = 'operator@example.com'; note = 'app check' } } |
            ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:rp 'state' 'app-1.json')
        @{ schemaVersion = 9; kind = 'migration'; runId = 'rr'; createdUtc = '2026-11-01T09:00:00Z' } | ConvertTo-Json | Set-Content (Join-Path $script:rp 'run.json')
        $html = Get-Content (New-VmfReport -OutPath $script:rp) -Raw
        # VERIFY-FP-1 part 3b: the Exceptions table, in the chosen report
        # style (Style A): day, month name, year - never month-first.
        $html | Should -Match '3 Nov 2026 10:00'
        $html | Should -Not -Match '11/03/2026'
    }
}
