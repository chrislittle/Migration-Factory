#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'stub' }
    # TEST-AZURE-GUARD-1: the guard comes AFTER the stand-ins above, so its mocks and this file's own take the same shape.
    Block-VmfAzureCalls -TestFile $PSCommandPath
}

AfterAll {
    Remove-Item -Path 'function:\Invoke-AzRestMethod' -ErrorAction SilentlyContinue
}

Describe 'Request-VmfQuota (P2-6)' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-qr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:runPath 'capacity') -Force | Out-Null
        function Global:WriteClaim {
            param($RunPath, $Name, $State, $BlockReason, $Used = 8, $Limit = 10, $Vcpus = 4)
            @{
                schemaVersion = 1; runId = 'r1'; wave = 'prod-1'; region = 'centralus'; zone = $null
                subscriptionId = '11111111-2222-3333-4444-555555555555'
                size = 'Standard_D2s_v6'; vmFamily = 'StandardDsv6Family'; state = $State
                blockReason = $BlockReason
                demand = @{ instances = 2; reservableInstances = 2; vcpus = $Vcpus }
                quota = @{ limit = $Limit; used = $Used; requestId = $null; requestedUtc = $null }
                notes = @()
            } | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $RunPath 'capacity' "$Name.json")
        }
        function Global:Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = '00000000-0000-0000-0000-000000000000' } } }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
        Remove-Item 'function:\Get-AzContext', 'function:\WriteClaim' -ErrorAction SilentlyContinue
    }

    It 'submits only quota-shortfall claims and records the request (202 pending)' {
        WriteClaim -RunPath $script:runPath -Name 'shortfall' -State 'BLOCKED' -BlockReason 'quota-shortfall'
        WriteClaim -RunPath $script:runPath -Name 'restricted' -State 'BLOCKED' -BlockReason 'sku-restricted'
        WriteClaim -RunPath $script:runPath -Name 'verified' -State 'QUOTA_VERIFIED' -BlockReason $null
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 202; Content = '{"id":"/quota-requests/abc-123"}' }
        }

        $result = Request-VmfQuota -OutPath $script:runPath
        @($result.Submitted).Count | Should -Be 1
        $result.Submitted[0].Family | Should -Be 'StandardDsv6Family'
        $result.Submitted[0].RequestedLimit | Should -Be 12   # used 8 + needed 4
        $result.Submitted[0].Status | Should -Be 'PENDING'

        $updated = Get-Content (Join-Path $script:runPath 'capacity' 'shortfall.json') -Raw | ConvertFrom-Json
        $updated.state | Should -Be 'QUOTA_REQUESTED'
        $updated.quota.requestId | Should -Be '/quota-requests/abc-123'
        (Get-Content (Join-Path $script:runPath 'capacity' 'restricted.json') -Raw | ConvertFrom-Json).state |
            Should -Be 'BLOCKED'
        Should -Invoke -ModuleName VmMigrationFactory Invoke-AzRestMethod -Times 1 -Exactly
    }

    It 'marks synchronous 200 as APPROVED' {
        WriteClaim -RunPath $script:runPath -Name 'shortfall' -State 'BLOCKED' -BlockReason 'quota-shortfall'
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = '{}' }
        }
        (Request-VmfQuota -OutPath $script:runPath).Submitted[0].Status | Should -Be 'APPROVED'
    }

    It 'asks Azure through our own seam, with the subscription in the path (QUOTA-BOUNDARY-1)' {
        # The other tests here mock Invoke-AzRestMethod - an AZURE cmdlet. That
        # works, and it is why nothing reported that this PUT sat outside the
        # azureops boundary for as long as it did. This one replaces OUR
        # function instead, which is the contract the rule exists to create.
        WriteClaim -RunPath $script:runPath -Name 'shortfall' -State 'BLOCKED' -BlockReason 'quota-shortfall'
        Mock -ModuleName VmMigrationFactory Get-VmfCurrentSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        $script:asked = $null
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease {
            $script:asked = [pscustomobject]@{
                SubscriptionId = $SubscriptionId; Location = $Location; Family = $Family; NewLimit = $NewLimit
            }
            [pscustomobject]@{ StatusCode = 200; Content = '{}' }
        }
        (Request-VmfQuota -OutPath $script:runPath).Submitted[0].Status | Should -Be 'APPROVED'
        # ID-ADDRESS-1: it said "read once and carried" - the session's
        # subscription, used for every claim. A claim's quota is in the
        # subscription its machines are in, which the claim records.
        $script:asked.SubscriptionId | Should -Be '11111111-2222-3333-4444-555555555555' -Because 'the request goes to the subscription the claim records, not the session''s'
        $script:asked.Location | Should -Be 'centralus'
        $script:asked.Family | Should -Be 'StandardDsv6Family'
        $script:asked.NewLimit | Should -Be 12 -Because 'used 8 plus the 4 this wave needs'
    }

    It 'records failures without mutating the claim' {
        WriteClaim -RunPath $script:runPath -Name 'shortfall' -State 'BLOCKED' -BlockReason 'quota-shortfall'
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 403; Content = 'AuthorizationFailed' }
        }
        $result = Request-VmfQuota -OutPath $script:runPath
        @($result.Failed).Count | Should -Be 1
        (Get-Content (Join-Path $script:runPath 'capacity' 'shortfall.json') -Raw | ConvertFrom-Json).state |
            Should -Be 'BLOCKED'
    }

    It 'WhatIfOnly reports without calling ARM' {
        WriteClaim -RunPath $script:runPath -Name 'shortfall' -State 'BLOCKED' -BlockReason 'quota-shortfall'
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { throw 'must not be called' }
        $result = Request-VmfQuota -OutPath $script:runPath -WhatIfOnly
        $result.All[0].Status | Should -Be 'WHATIF'
        Should -Invoke -ModuleName VmMigrationFactory Invoke-AzRestMethod -Times 0
    }
}

Describe 'New-VmfReport (P2-5)' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rpt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:runPath -Force | Out-Null
        @{
            schemaVersion = 17; runId = 'r1'; generatedUtc = '2026-08-24T00:00:00Z'
            scope = @{ subscriptions = @('s') }
            summary = @{ ReadyAfterPrep = 1; Blocked = 1 }
            vms = @(
                @{ vmId = '/s/rg/vm/web-01'; name = 'web-01'; classification = 'ReadyAfterPrep'; os = 'Windows'
                   gen = 'V2'; sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'; ring = 'prod'
                   iacManaged = $true; blockers = @(); prepNeeded = @('stornvme', 'pagefile'); notes = @() },
                @{ vmId = '/s/rg/vm/old-01'; name = 'old-<script>&01'; classification = 'Blocked'; os = 'Windows'
                   gen = 'V1'; sourceSize = 'Standard_D2_v2'; sourceDiskArch = 'scsi-temp'; ring = $null
                   iacManaged = $false; blockers = @('gen1-requires-redeploy'); prepNeeded = @(); notes = @() }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'assessment.json')
        @{
            schemaVersion = 1; generatedUtc = 'x'; assessmentRunId = 'r1'
            pathSummary = @(@{ path = 'A'; count = 1 }; @{ path = 'MANUAL'; count = 1 })
            waveSummary = @(@{ wave = 'prod-1'; count = 1 })
            entries = @(@{ schemaVersion = (Get-VmfTestPlanEntryVersion);
                vmId = '/s/rg/vm/web-01'; wave = 'prod-1'; path = 'A'
                assessment = @{ sourceSize = 'Standard_D2ds_v4'; location = 'centralus' }
                target = @{ size = 'Standard_D2ds_v6'; sizeAlternates = @('Standard_D2s_v6') }
                planNotes = @()
            })
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'plan.json')
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'OLD-VERSION-READERS-REMOVE-1: the report has no section for an identity a rebuild deleted, whatever the event log holds' {
        # No step of this version writes such a line: no move and no restore
        # rebuilds a machine, and nobody holds a run an earlier version made
        # (2026-11-11). A line of that shape in the log is not read.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'r1' | Out-Null
            Write-VmfEvent -RunPath $rp -Step 'identity' -Outcome warn -VmId '/s/rg/vm/moved-03' -Detail 'deleted' `
                -Data @{ identityDeleted = $true; oldPrincipalId = 'cccccccc-0000-0000-0000-000000000003' }
        }
        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        $html | Should -Not -Match 'System-assigned identities that a rebuild deleted'
        $html | Should -Not -Match 'cccccccc-0000-0000-0000-000000000003'
    }
    It 'and says nothing at all when no machine lost one' {
        # A section that renders empty headings for every run is noise, and a
        # customer reading "Identities replaced by a rebuild" with no rows
        # would reasonably wonder what went wrong.
        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        $html | Should -Not -Match 'System-assigned identities that a rebuild deleted'
    }

    # REPORT-AUTO-1 REWROTE these two. They pinned the engineering appendix -
    # the assessment, plan and execution tables, with classification codes and
    # script names - which went when the report became one kind
    # (2026-10-02). Those facts are in the migration record now, and
    # ReportAuto.Tests.ps1 finds each one there. What still holds: the report
    # is self-contained, and nothing from the store reaches it raw.
    It 'renders a self-contained report with no engineering appendix, and escapes HTML' {
        # Review 9: the hostile name used to sit only in the assessment, which
        # this report no longer shows - so "never raw" could not fail. Here it
        # is a planned machine of a migration, which the Machines table lists.
        @{ schemaVersion = 9; kind = 'migration'; runId = 'r1'; createdUtc = '2026-11-01T09:00:00Z' } |
            ConvertTo-Json | Set-Content (Join-Path $script:runPath 'run.json')
        $plan = Get-Content (Join-Path $script:runPath 'plan.json') -Raw | ConvertFrom-Json
        $plan.entries = @($plan.entries) + @([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/old-<script>&01'; wave = 'prod-1'; path = 'A'
            assessment = @{ sourceSize = 'Standard_D2_v2' }; target = @{ size = 'Standard_D2ds_v6' }; planNotes = @() })
        $plan | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'plan.json')
        $path = New-VmfReport -OutPath $script:runPath
        Test-Path $path | Should -BeTrue
        $html = (Get-VmfPageSource -Path $path)
        $html | Should -Not -Match 'gen1-requires-redeploy|ReadyAfterPrep|Fleet assessment|Migration plan'
        $machines = [regex]::Match($html, '(?s)3</span> Machines.*?</section>').Value
        $machines | Should -Match 'old-&lt;script&gt;&amp;01' -Because 'the hostile name is shown, encoded'
        $html | Should -Not -Match '<script>&01' -Because 'and never raw'
        # self-contained: no external stylesheet/script references
        $html | Should -Not -Match 'https?://[^"]*\.(css|js)'
    }

    It 'does not show the execution table: the checkpoint and the scripts are in the record' {
        New-Item -ItemType Directory -Path (Join-Path $script:runPath 'state') -Force | Out-Null
        @{
            schemaVersion = (Get-VmfTestStateVersion); runId = 'r1'; vmId = '/s/rg/vm/web-01'; state = 'MIGRATED'
            pathCheckpoint = 'B:recreated'
            guestExecutions = @(@{ script = 'Set-NvmeReady.ps1'; result = 'FIXED'; version = '1.0.0'; sha256 = ('0' * 64); tsUtc = 'x' })
            history = @(@{ tsUtc = 'x'; state = 'MIGRATED'; outcome = 'ok'; detail = 'done' })
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'state' 'web-01.json')

        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        $html | Should -Not -Match 'Migration execution'
        $html | Should -Not -Match 'Set-NvmeReady\.ps1=FIXED|B:recreated'
    }
}

Describe 'New-VmfReport (REPORT-1)' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-crpt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:runPath 'state') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $script:runPath 'capacity') -Force | Out-Null
        # VERIFY-FP-1 part 3b: the report renders the migration record, which
        # starts from the run's manifest.
        @{ schemaVersion = 9; kind = 'migration'; runId = 'r1'; createdUtc = '2026-11-01T09:00:00Z' } |
            ConvertTo-Json | Set-Content (Join-Path $script:runPath 'run.json')
        @{
            schemaVersion = 1; generatedUtc = 'x'; assessmentRunId = 'r1'
            pathSummary = @(@{ path = 'A'; count = 2 })
            waveSummary = @(@{ wave = 'prod-1'; count = 2 })
            entries = @(
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/tf-web'; wave = 'prod-1'; path = 'A'
                   assessment = @{ sourceSize = 'Standard_D4ds_v4'; location = 'centralus'; iacManaged = $true }
                   target = @{ size = 'Standard_D4ds_v6'; controller = 'NVMe' }; planNotes = @() },
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/broken-01'; wave = 'prod-1'; path = 'A'
                   assessment = @{ sourceSize = 'Standard_D2ds_v4'; location = 'centralus'; iacManaged = $false }
                   target = @{ size = 'Standard_D2ds_v6'; controller = 'NVMe' }; planNotes = @() }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'plan.json')
        @{
            schemaVersion = (Get-VmfTestStateVersion); runId = 'r1'; vmId = '/s/rg/vm/tf-web'; state = 'MIGRATED'
            # What PRECHECK records on every machine it passes: the capture, the
            # first capture beside it, and the move it started.
            captured = @{
                vmConfig = @{ size = 'Standard_D4ds_v4'; controller = 'SCSI'; capacityReservationGroupId = $null; patchSettings = $null }
                original = @{ vmConfig = @{ size = 'Standard_D4ds_v4'; controller = 'SCSI'; capacityReservationGroupId = $null; patchSettings = $null } }
                startedTarget = @{ path = 'A'; size = 'Standard_D4ds_v6'; controller = 'NVMe' } }
            guestExecutions = @(
                @{ script = 'Test-GuestValidation.ps1'; result = 'PASS'; version = '1.0.0'; sha256 = ('0' * 64); tsUtc = 'x' },
                @{ script = 'Test-ManaReady.ps1'; result = 'READY'; version = '1.0.0'; sha256 = ('0' * 64); tsUtc = 'x' },
                @{ script = 'Test-DataDiskSeed.ps1'; result = 'PASS'; version = '1.0.0'; sha256 = ('0' * 64); tsUtc = 'x' }
            )
            history = @(
                @{ tsUtc = '2026-11-02T02:00:00Z'; state = 'PRECHECK'; outcome = 'ok' },
                @{ tsUtc = '2026-11-02T02:14:00Z'; state = 'MIGRATED'; outcome = 'ok' }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'state' 'tf-web.json')
        @{
            schemaVersion = (Get-VmfTestStateVersion); runId = 'r1'; vmId = '/s/rg/vm/broken-01'; state = 'FAILED_ROLLED_BACK'
            guestExecutions = @()
            history = @(
                @{ tsUtc = '2026-11-02T02:00:00Z'; state = 'PRECHECK'; outcome = 'ok' },
                @{ tsUtc = '2026-11-02T02:20:00Z'; state = 'FAILED_ROLLED_BACK'; outcome = 'fail'
                   detail = 'STARTING failed; rolled back to original config: agent timeout'
                   evidenceRef = 'bootdiag-broken-01.json' }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'state' 'broken-01.json')
        @{
            schemaVersion = 1; runId = 'r1'; wave = 'prod-1'; region = 'centralus'; zone = $null
            size = 'Standard_D4ds_v6'; vmFamily = 'StandardDdsv6Family'; state = 'RELEASED'; blockReason = $null
            demand = @{ instances = 1; reservableInstances = 1; vcpus = 4 }
            quota = @{ limit = 10; used = 0; requestId = $null; requestedUtc = $null }
            reservation = @{ groupId = 'g'; reservationId = 'r'; createdUtc = '2026-11-01T14:00:00Z'
                             releasedUtc = '2026-11-02T03:00:00Z'; consumedInstances = 1 }
            associatedVmIds = @('/s/rg/vm/tf-web'); notes = @()
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'capacity' 'c1.json')
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'SEC-REPORT-1: COMPOSED fields are escaped too, not only the machine name' {
        # The escaping test in the other Describe plants a hostile VM NAME, and
        # every DIRECT field goes through Encode. Two strings were BUILT first
        # and then interpolated raw - the size pair in the Terraform section,
        # and the reservation window below - so the discipline had a hole
        # exactly where a reader would not look for one.
        #
        # It matters because of where the report is RENDERED. reports.html
        # fetches it with the viewer's token and shows it; that window used to
        # inherit the dashboard's own origin, which is where MSAL keeps the
        # access token and where the CSP allows inline script. Nothing reached
        # these fields from an attacker - a size name comes from Azure's
        # catalog - but that is a fact about Azure's data, not a property of
        # this code, and nobody re-checks it when a field is added.
        # The size comes from the machine's record (OLD-STATE-READERS-FINISH-1).
        $doc = Get-Content (Join-Path $script:runPath 'state' 'tf-web.json') -Raw | ConvertFrom-Json
        $doc.captured.vmConfig.size = 'Standard_<script>alert(1)</script>_v4'
        $doc.captured.original.vmConfig.size = 'Standard_<script>alert(1)</script>_v4'
        $doc | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'state' 'tf-web.json')

        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        $html | Should -Match 'Changes to match in your infrastructure code' -Because 'the section under test has to render at all'
        $html | Should -Not -Match '<script>alert\(1\)</script>' -Because 'a composed string needs Encode on the PARTS'
        $html | Should -Match 'Standard_&lt;script&gt;'
    }

    It 'and the reservation window is escaped, which is the other composed one' {
        $claim = Get-Content (Join-Path $script:runPath 'capacity' 'c1.json') -Raw | ConvertFrom-Json
        $claim.reservation.createdUtc = '<img src=x onerror=alert(1)>'
        $claim | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'capacity' 'c1.json')

        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        $html | Should -Match 'Capacity' -Because 'the section under test has to render at all'
        $html | Should -Not -Match '<img src=x onerror' -Because 'a timestamp is store data like any other'
        $html | Should -Match '&lt;img src=x'
    }

    It 'STATE-TARGET-1: the code table gives the target the machine STARTED on, not an entry changed since' {
        $doc = Get-Content (Join-Path $script:runPath 'state' 'tf-web.json') -Raw | ConvertFrom-Json
        $doc.captured | Add-Member -NotePropertyName startedTarget -NotePropertyValue ([pscustomobject]@{ path = 'A'; size = 'Standard_D4ds_v6'; controller = 'NVMe' }) -Force
        $doc | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'state' 'tf-web.json')
        $plan = Get-Content (Join-Path $script:runPath 'plan.json') -Raw | ConvertFrom-Json
        $plan.entries[0].target.size = 'Standard_D4ds_v5'; $plan.entries[0].target.controller = 'SCSI'
        $plan | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'plan.json')

        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        $row = [regex]::Match($html, '<tr><td>tf-web</td><td>Standard_D4ds_v4 to .*?</tr>').Value
        $row | Should -Match 'Standard_D4ds_v4 to Standard_D4ds_v6'
        $row | Should -Match 'SCSI to NVMe'
    }

    It 'renders the chosen report: results, moves, machines, exceptions, sign-off - then the follow-up' {
        # VERIFY-FP-1 part 3b (Style A, 2026-09-28). The old executive summary,
        # checklist and narrative sections are gone: "this needs real work to
        # focus as a report not a bunch of prose".
        $path = New-VmfReport -OutPath $script:runPath -Title 'Wave prod-1 Report'
        $path | Should -Match 'customer-report\.html$'
        $html = (Get-VmfPageSource -Path $path)
        foreach ($section in '1</span> Results', '2</span> Moves', '3</span> Machines', '4</span> Exceptions', '5</span> Sign-off') {
            $html | Should -Match ([regex]::Escape($section))
        }
        $html | Should -Not -Match 'Executive summary'
        $html | Should -Match '<svg viewBox="0 0 32 32"' -Because 'the product mark is on the cover'
        $html | Should -Match 'Migration Factory'
        $html | Should -Match 'Rolled back'
        $html | Should -Match 'Changes to match in your infrastructure code'
        $html | Should -Match 'Standard_D4ds_v4 to Standard_D4ds_v6'
        $html | Should -Match 'The product does not change your code'
        $html | Should -Match 'Capacity and cost'
        $html | Should -Match 'StandardDdsv6Family'
        # REPORT-WORDS-1: no engineering appendix in the customer's copy, and no
        # internal word - "Path A" and "Path B" were found there.
        $html | Should -Not -Match 'Appendix'
        $html | Should -Not -Match 'Path [AB]\b|>A</span>|>B</span>|NEEDS_DECISION|FAILED_ROLLED_BACK|ReadyAfterPrep|\.ps1='
        # REPORT-AUTO-1: there is no second, engineering kind to compare with -
        # this is the one report, and the method is named in words.
        $html | Should -Match '<td>In-place upgrade</td>'
    }

    It 'TERMS-AUDIT-1: the capacity table says its words - no "&", no engine state, and nothing reserved without a reservation' {
        # The lab report (2026-11-05) showed QUOTA_VERIFIED, the heading
        # "Capacity & commercial", and a Reserved count of 1 beside "no
        # reservation (BestEffort)": it reserved nothing, so it says nothing.
        @{
            schemaVersion = 2; runId = 'r1'; wave = 'prod-1'; region = 'centralus'; zone = $null
            size = 'Standard_E2s_v6'; vmFamily = 'StandardEsv6Family'; state = 'QUOTA_VERIFIED'; blockReason = $null
            demand = @{ instances = 1; reservableInstances = 1; vcpus = 2 }
            quota = @{ limit = 10; used = 0; requestId = $null; requestedUtc = $null }
            notes = @()
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'capacity' 'c3.json')
        try {
            $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
            $section = [regex]::Match($html, '(?s)<h2>Capacity and cost</h2>.*?</table>').Value
            $section | Should -Not -BeNullOrEmpty -Because 'the heading says "and"'
            $html | Should -Not -Match 'Capacity &amp;'
            $row = [regex]::Match($section, '<tr><td>Standard_E2s_v6 @ centralus</td>.*?</tr>').Value
            $row | Should -Match '<td>-</td><td>-</td><td>-</td><td>No capacity reservation</td>' -Because 'a claim with no reservation reserved nothing'
            $row | Should -Match '>Quota checked</span>'
            $section | Should -Match '>Released</span>' -Because 'every state is said in words'
            $section | Should -Not -MatchExactly 'QUOTA_VERIFIED|RELEASED|BestEffort|[Gg]eneral capacity'
        }
        finally { Remove-Item (Join-Path $script:runPath 'capacity' 'c3.json') -Force }
    }

    It 'shows the reduced reservation guarantee for AvSet workloads (CAP-2)' {
        @{
            schemaVersion = 2; runId = 'r1'; wave = 'prod-1'; region = 'centralus'; zone = $null
            size = 'Standard_D2s_v6'; vmFamily = 'StandardDsv6Family'; state = 'RELEASED'; blockReason = $null
            demand = @{ instances = 4; reservableInstances = 2; vcpus = 8 }
            quota = @{ limit = 10; used = 0; requestId = $null; requestedUtc = $null }
            reservation = @{ groupId = 'g2'; reservationId = 'r2'; createdUtc = '2026-11-01T14:00:00Z'
                             releasedUtc = '2026-11-02T03:00:00Z'; consumedInstances = 2 }
            notes = @('2 of 4 machines are in an availability set. Azure does not allow an on-demand capacity reservation for them, so they move without one.')
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:runPath 'capacity' 'c2.json')

        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        # Reserved column carries the RESERVABLE count (2), never total demand (4)
        $html | Should -Match 'Standard_D2s_v6 @ centralus</td><td>2</td><td>2</td>'
        # the platform-limitation explanation is spelled out for stakeholders
        $html | Should -Match 'Azure does not allow a capacity reservation for a machine in an availability set\.'
        # the v1-shaped claim (no reservableInstances) shows no general-capacity portion
        $html | Should -Match 'Standard_D4ds_v6 @ centralus</td><td>1</td><td>-</td>'
    }

    # REPORT-AUTO-1 REWROTE these two. The first pinned a sign-off typed into
    # the "Produce the report" dialog; the second, the Operator report written
    # to report.html, which the Reports page never opened (REPORT-OWN-1). Both
    # were removed on 2026-10-02: the engine writes one report, and its
    # sign-off is the decisions the product records.
    It 'the sign-off says when no approval is recorded, and has no row for the report itself' {
        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        $signoff = [regex]::Match($html, '(?s)5</span> Sign-off.*?</table>').Value
        $signoff | Should -Match 'No approval is recorded\.'
        $signoff | Should -Not -Match '<td>Report'
    }

    It 'there is one report: customer-report.html, never report.html' {
        $path = New-VmfReport -OutPath $script:runPath
        $path | Should -Match '[\\/]customer-report\.html$'
        Test-Path (Join-Path $script:runPath 'report.html') | Should -BeFalse
        ((Get-VmfPageSource -Path $path)) | Should -Match 'Changes to match in your infrastructure code'
    }

    It 'an assessment is not a migration: its report has no migration sections' {
        @{ schemaVersion = 9; kind = 'assessment'; runId = 'r1'; createdUtc = '2026-11-01T09:00:00Z' } | ConvertTo-Json | Set-Content (Join-Path $script:runPath 'run.json')
        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        $html | Should -Not -Match '1</span> Results'
        # REPORT-AUTO-1: and no appendix either - there is none.
        $html | Should -Not -Match 'Appendix'
    }

    It 'a summary the product could not build is said, on the page and in the log' {
        Mock -ModuleName VmMigrationFactory Get-VmfMigrationRecordFromStore { throw 'the record store is not readable' }
        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        $html | Should -Match 'could not build the summary of this migration'
        $html | Should -Match 'the record store is not readable'
        (Get-Content (Join-Path $script:runPath 'logs' 'events.jsonl') -Raw) | Should -Match 'could not build the migration record for the report'
    }

    It 'VERIFY-FP-1 part 3b: times read from the store are UTC, whatever the time zone of the machine that builds the report' {
        # The state documents are read through ConvertFrom-Json, which makes a
        # time a date value. The record used to [string] it - month-first, no
        # zone - and the report then read it as local time: on a host five
        # hours from UTC, 02:00Z printed as 07:00 "UTC".
        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        $html | Should -Match '2 Nov 2026, 02:00&ndash;02:20 UTC'
        $html | Should -Match 'tf-web</div>.*?02:00&ndash;02:14'
    }

    It 'VERIFY-FP-1 part 3b: an exception gives the product''s own words and the file the step kept' {
        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        $row = [regex]::Match([regex]::Match($html, '(?s)4</span> Exceptions.*?</section>').Value, '(?s)broken-01</td>.*?</tr>').Value
        $row | Should -Match 'A step failed, and the product restored the machine\.'
        $row | Should -Not -Match 'agent timeout' -Because 'the engine''s own message is not a sentence for a customer'
        $row | Should -Match 'Evidence file: <span class="mono">bootdiag-broken-01\.json</span>'
    }
}

# COUNT-1: the counts this page renders WITHOUT esc() must be numbers.
#
# tests/js/report-counts.test.js proves num() neutralises a payload. This
# proves num() is actually APPLIED where the counts are computed - the two
# halves fail differently, and the JavaScript test alone would pass on a page
# that declares num() and never calls it.
#
# Read with comments stripped: the page now explains the old defect in prose,
# including the expression it replaced, so a whole-file match would find the
# explanation and pass either way (COMMENT-TRAP-1).
Describe 'COUNT-1: every unescaped count on the Reports page is made numeric' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:reportsCode = Get-VmfCodeOnly -Path (Join-Path $PSScriptRoot '..' '..' 'src' 'dashboard' 'reports.html')
    }

    It 'declares the coercion' {
        $script:reportsCode | Should -Match 'function num\(v\)'
        $script:reportsCode | Should -Match 'Number\.isFinite\(n\) \? n : 0'
    }

    It 'and every count field is built through it' {
        # These feed the interpolations that carry no esc().
        # COUNT-TRUTH-1: they come from the service's outcome counts now, not
        # from stateCounts - and a count from the service is store data just the
        # same, so it goes through num() just the same.
        $script:reportsCode | Should -Match 'migrated: num\(o\.migrated\)'
        $script:reportsCode | Should -Match 'putBack: num\(o\.putBack\)'
        $script:reportsCode | Should -Match 'restored: num\(o\.rolledBack\)'
        $script:reportsCode | Should -Match 'attention: num\(o\.attention\)'
        # total and waves are counted from the plan's own array, so they are
        # lengths - numbers by construction, not values read from a document.
        $script:reportsCode | Should -Match 'total: entries\.length,'
        $script:reportsCode | Should -Match 'waves: new Set\(entries\.map\(e => e\.wave\)\)\.size,'
        $script:reportsCode | Should -Match 'reduce\(\(a, c\) => a \+ num\(c\.demand\?\.reservableInstances\), 0\)'
    }

    It 'and the old shape is gone - ?? does not make a number' {
        # `??` replaces only null and undefined, so a string survives it and the
        # addition that follows concatenates. This is the exact expression that
        # shipped, and it must not come back.
        $script:reportsCode | Should -Not -Match '\(counts\.MIGRATED \?\? 0\)'
        $script:reportsCode | Should -Not -Match '\(counts\[s\] \?\? 0\)'
        $script:reportsCode | Should -Not -Match 'counts\.FAILED_ROLLED_BACK \?\? 0'
    }
}

# REPORT-GAP-1: the report must SAY what the scan could not read.
#
# A source check proved the wording existed in the file. It did not prove the
# block was reachable - putting the whole section behind `if ($false)` left
# that test passing, which is how a report could silently lose the one thing
# this item exists to add. These RUN the report.
Describe 'REPORT-GAP-1: the customer report says what the scan could not read' {
    BeforeEach {
        $script:gapRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-gap-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:gapRun -Force | Out-Null
    }
    AfterEach { if (Test-Path $script:gapRun) { Remove-Item $script:gapRun -Recurse -Force } }
    AfterAll { Remove-Item 'function:\WriteGapAssessment' -ErrorAction SilentlyContinue }

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        # Defined here, not in the Describe body: a function declared in the
        # body runs at DISCOVERY and is not in scope when an It actually runs.
        function Global:WriteGapAssessment {
        param([string]$RunPath, $NotRead)
        $doc = [ordered]@{
            schemaVersion = 17; runId = 'gap'; generatedUtc = '2026-09-13T00:00:00Z'
            scope = @{ subscriptions = @('s') }
            summary = @{ ReadyNow = 1 }
            vms = @(@{ vmId = '/s/rg/vm/a'; name = 'a'; classification = 'ReadyNow'; os = 'Windows'
                       gen = 'V2'; sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'
                       iacManaged = $false; blockers = @(); prepNeeded = @(); notes = @() })
        }
        if ($null -ne $NotRead) { $doc.notRead = $NotRead }
        $doc | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $RunPath 'assessment.json')
        }
    }

    It 'names the subject in words a customer can act on' {
        WriteGapAssessment -RunPath $script:gapRun -NotRead @(
            @{ subject = 'acceleratedNetworking'; detail = 'HTTP 403 from the network provider' })
        $html = Get-Content (New-VmfReport -OutPath $script:gapRun) -Raw
        $html | Should -Match 'What this scan could not read'
        $html | Should -Match 'Accelerated networking'
        # FLAKY-403-1: the engine's own words, not the digits alone - the report
        # also prints when it was made, and a time such as 14:03 contains 403.
        $html | Should -Not -Match 'HTTP 403' -Because 'the engine exception is not for a customer to read'
        $html | Should -Not -Match 'network provider'
    }

    It 'says NOTHING when the scan read everything it asked for' {
        # A heading with nothing under it makes a clean scan look suspicious.
        WriteGapAssessment -RunPath $script:gapRun -NotRead @()
        $html = Get-Content (New-VmfReport -OutPath $script:gapRun) -Raw
        $html | Should -Not -Match 'What this scan could not read'
    }

    It 'and does not throw on an assessment written before the field existed' {
        # Set-StrictMode makes reading an absent member an ERROR, so an old
        # assessment would break the whole report rather than have nothing to
        # say. The report is the last artifact of a finished migration; failing
        # to produce it is worse than the gap being fixed.
        WriteGapAssessment -RunPath $script:gapRun -NotRead $null
        { New-VmfReport -OutPath $script:gapRun } | Should -Not -Throw
        $html = Get-Content (New-VmfReport -OutPath $script:gapRun) -Raw
        $html | Should -Not -Match 'What this scan could not read'
        $html | Should -Match 'Migration Factory' -Because 'the rest of the report still renders'
        # REPORT-WORDS-1 and REPORT-AUTO-1: the assessment table is engineering
        # detail - the migration record holds it, and the one report does not.
        $html | Should -Not -Match 'Fleet assessment'
    }

    It 'a subject with no wording is still named, never dropped' {
        WriteGapAssessment -RunPath $script:gapRun -NotRead @(@{ subject = 'somethingNew' })
        $html = Get-Content (New-VmfReport -OutPath $script:gapRun) -Raw
        $html | Should -Match 'What this scan could not read'
        $html | Should -Match 'somethingNew' -Because 'a silent omission is the defect being fixed'
    }
}
