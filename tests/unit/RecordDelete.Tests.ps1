#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RECORD-DELETE-1: a record download is refused while a delete of the same
# migration runs.
#
# Found by the review of REPORT-RECORD-LINE-1: since a download keeps the record
# and leaves a 'record' line in the run history, a download that raced a delete
# could write the activity file back into the run folder the delete had just
# removed - a folder with no run.json that nothing cleans. Worse, it could keep
# a record built from a run that was half deleted over the record the delete
# kept, and hand it to the person as the record of the migration.
#
# Two parts, each the product's own mechanism:
#   1. The service refuses the download while a delete with the safety copies
#      is open in the log and Azure lists its job - the check that already
#      refuses restore, rebuild, retry and a wave start (DISCARD-ENGINE-1 S2).
#   2. The download itself, after it built the record and before it keeps it,
#      refuses when the delete has started to remove the migration: the
#      migration's run.json is gone, or the kept record is the one a delete
#      kept (a delete keeps it BEFORE it removes anything). And it keeps the
#      record only if that kept record has not changed since it was read
#      (PLAN-WRITE-RACE-1: the check and the write are one step).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    # One migration, one machine that migrated - built by the engine's own
    # functions, so every document is the shape it writes.
    function Global:RdRun {
        $store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rd-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $run = Join-Path $store 'mig-1'
        $vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/web'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; vm = $vm } {
            Initialize-VmfRun -RunPath $rp -RunId 'mig-1' -Kind 'migration' -FromAssessment 'scan-1' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{
                schemaVersion = 8; assessmentRunId = 'scan-1'
                entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'w1'; path = 'A'
                    assessment = [ordered]@{ sourceSize = 'Standard_D2s_v4' }
                    target = [ordered]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' } }) })
            New-VmfStateDoc -RunPath $rp -RunId 'mig-1' -VmId $vm -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'MIGRATED' -Outcome ok | Out-Null
        }
        @{ Store = $store; Run = $run; Vm = $vm; Kept = (Join-Path $store 'vmf-records' 'mig-1.json') }
    }
    # The 'record' lines in the run history.
    function Global:RdRecordLines([string]$RunPath) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath } {
            @(Read-VmfEvents -RunPath $rp | Where-Object { $_.step -eq 'record' -and $_.outcome -eq 'ok' })
        }
    }
    # What a delete does first: it keeps the record of the migration, with the
    # reason 'deleted', before it removes anything (ATTEST-1).
    function Global:RdKeepDeletedRecord([string]$RunPath) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath } {
            New-VmfMigrationRecord -RunPath $rp -Reason 'deleted' -GeneratedBy 'operator@example.com' | Out-Null
        }
    }
    # The real functions, taken before any mock, so a test can mock one call
    # of a function and send every other call to the real one. Pester 5 falls
    # through to the real function when no -ParameterFilter matches; Pester 6
    # does not, so every filtered mock here has a default beside it that calls
    # through (review 8).
    $global:RdReal = & (Get-Module VmMigrationFactory) {
        @{ Build    = ${function:Get-VmfMigrationRecordFromStore}
           ReadText = ${function:Read-VmfTextDocument}
           Exists   = ${function:Test-VmfStoreItem} }
    }
    function Global:RdCallThrough {
        Mock -ModuleName VmMigrationFactory Get-VmfMigrationRecordFromStore { & $global:RdReal.Build @PesterBoundParameters }
        Mock -ModuleName VmMigrationFactory Read-VmfTextDocument { & $global:RdReal.ReadText @PesterBoundParameters }
        Mock -ModuleName VmMigrationFactory Test-VmfStoreItem { & $global:RdReal.Exists @PesterBoundParameters }
    }
    # The 'discard' failure lines in the run history.
    function Global:RdStopLines([string]$RunPath) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath } {
            @(Read-VmfEvents -RunPath $rp | Where-Object { $_.step -eq 'discard' -and $_.outcome -eq 'fail' })
        }
    }
}
AfterAll {
    Remove-Item 'function:\RdRun', 'function:\RdRecordLines', 'function:\RdKeepDeletedRecord', 'function:\RdCallThrough', 'function:\RdStopLines' -ErrorAction SilentlyContinue
    Remove-Variable -Name RdReal -Scope Global -ErrorAction SilentlyContinue
}

Describe 'RECORD-DELETE-1: the download, with no delete' {
    BeforeEach { $script:fx = RdRun }
    AfterEach { if (Test-Path $script:fx.Store) { Remove-Item $script:fx.Store -Recurse -Force } }

    It 'is made, kept and returned, and leaves its line, when no record was kept before' {
        $r = Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com'
        $r.reason | Should -Be 'downloaded'
        (Get-Content $script:fx.Kept -Raw | ConvertFrom-Json -Depth 32).reason | Should -Be 'downloaded'
        @(RdRecordLines $script:fx.Run).Count | Should -Be 1
    }

    It 'replaces a record that a wave kept, and a second download replaces its own' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            New-VmfMigrationRecord -RunPath $rp -Reason 'waveClosed' | Out-Null
        }
        Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com' | Out-Null
        (Get-Content $script:fx.Kept -Raw | ConvertFrom-Json -Depth 32).reason | Should -Be 'downloaded'
        Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'other@example.com' | Out-Null
        (Get-Content $script:fx.Kept -Raw | ConvertFrom-Json -Depth 32).generatedBy | Should -Be 'other@example.com'
    }

    It 'every other writer of the record is not changed: a wave keeps it over the record a delete kept' {
        # The refusal is the download's. A delete is refused while a wave,
        # restore runs (DISCARD-ENGINE-1 review 2 item 3), so those
        # writers keep what they always kept.
        RdKeepDeletedRecord $script:fx.Run
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            New-VmfMigrationRecord -RunPath $rp -Reason 'waveClosed' | Out-Null
        }
        (Get-Content $script:fx.Kept -Raw | ConvertFrom-Json -Depth 32).reason | Should -Be 'waveClosed'
    }
}

Describe 'RECORD-DELETE-1: the download refuses a migration that a delete has started to remove' {
    BeforeEach {
        $script:fx = RdRun
        $script:deleteSays = '409: A delete of this migration started*'
        RdCallThrough
    }
    AfterEach {
        if (Test-Path $script:fx.Store) { Remove-Item $script:fx.Store -Recurse -Force }
        Remove-Variable -Name RdFx, RdCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'THE POINT: a delete that ran to the end while the record was built - refused, and nothing written back' {
        $global:RdFx = $script:fx
        Mock -ModuleName VmMigrationFactory Get-VmfMigrationRecordFromStore -ParameterFilter { $Reason -eq 'downloaded' } {
            # The delete, whole, between the download's reads and its write.
            Remove-VmfRun -RunPath $global:RdFx.Run -Reason 'done' -RemovedBy 'operator@example.com' -KeepSafetyCopies -Confirm:$false | Out-Null
            [ordered]@{ schemaVersion = 3; runId = 'mig-1'; project = ''; reason = 'downloaded'; machines = @() }
        }
        { Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com' } | Should -Throw $script:deleteSays
        Test-Path $script:fx.Run | Should -BeFalse -Because 'nothing may write the run folder back - that is the orphan'
        (Get-Content $script:fx.Kept -Raw | ConvertFrom-Json -Depth 32).reason | Should -Be 'deleted' -Because 'the record the delete kept stays'
    }

    It 'refuses when the run itself is gone after the build, even with no record kept' {
        $global:RdFx = $script:fx
        Mock -ModuleName VmMigrationFactory Get-VmfMigrationRecordFromStore -ParameterFilter { $Reason -eq 'downloaded' } {
            Remove-Item (Join-Path $global:RdFx.Run 'run.json') -Force
            [ordered]@{ schemaVersion = 3; runId = 'mig-1'; project = ''; reason = 'downloaded'; machines = @() }
        }
        { Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com' } | Should -Throw $script:deleteSays
        Test-Path $script:fx.Kept | Should -BeFalse -Because 'a record of a half-removed migration is never kept'
        @(RdRecordLines $script:fx.Run).Count | Should -Be 0
    }

    It 'refuses when a delete kept its record before the download began' {
        RdKeepDeletedRecord $script:fx.Run
        $before = Get-Content $script:fx.Kept -Raw
        { Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com' } | Should -Throw $script:deleteSays
        Get-Content $script:fx.Kept -Raw | Should -BeExactly $before -Because 'the record the delete kept is never replaced by a download'
        @(RdRecordLines $script:fx.Run).Count | Should -Be 1 -Because 'only the delete''s own line, none from the download'
    }

    It 'refuses when a delete kept its record while the download built its own' {
        $global:RdFx = $script:fx
        Mock -ModuleName VmMigrationFactory Get-VmfMigrationRecordFromStore -ParameterFilter { $Reason -eq 'downloaded' } {
            RdKeepDeletedRecord $global:RdFx.Run
            [ordered]@{ schemaVersion = 3; runId = 'mig-1'; project = ''; reason = 'downloaded'; machines = @() }
        }
        { Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com' } | Should -Throw $script:deleteSays
        (Get-Content $script:fx.Kept -Raw | ConvertFrom-Json -Depth 32).reason | Should -Be 'deleted'
    }

    It 'the check and the keep are one step: a delete that keeps its record just after the check still wins' {
        # A record was kept before (a wave). The delete keeps its own between
        # the download's last read of it (the check) and the download's write.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            New-VmfMigrationRecord -RunPath $rp -Reason 'waveClosed' | Out-Null
        }
        $global:RdFx = $script:fx
        $global:RdCalls = 0
        Mock -ModuleName VmMigrationFactory Read-VmfTextDocument -ParameterFilter { $Path -like '*vmf-records*' } {
            $text = Get-Content -LiteralPath $Path -Raw
            # 1: the version before the build. 2: the check after it.
            if (++$global:RdCalls -eq 2) { RdKeepDeletedRecord $global:RdFx.Run }
            $text
        }
        { Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com' } | Should -Throw '409: *written again*'
        $global:RdCalls | Should -Be 2 -Because 'the delete landed after the check, so the store refused the write'
        (Get-Content $script:fx.Kept -Raw | ConvertFrom-Json -Depth 32).reason | Should -Be 'deleted'
        @(RdRecordLines $script:fx.Run | Where-Object { $_.tsUtc }).Count | Should -Be 2 -Because 'the wave''s line and the delete''s, none from the download'
    }

    It 'and the same when no record was kept before: the first keep is a create that only one writer wins' {
        $global:RdFx = $script:fx
        $global:RdCalls = 0
        Mock -ModuleName VmMigrationFactory Test-VmfStoreItem -ParameterFilter { $RunPath -like '*vmf-records' } {
            # 1: nothing kept before the build. 2: nothing at the check; the
            # delete keeps its record just after it.
            if (++$global:RdCalls -eq 2) { RdKeepDeletedRecord $global:RdFx.Run }
            $false
        }
        { Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com' } | Should -Throw '409: *written again*'
        (Get-Content $script:fx.Kept -Raw | ConvertFrom-Json -Depth 32).reason | Should -Be 'deleted'
    }

    It 'review 2: a record a wave keeps while the download builds is not replaced by the older one' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            New-VmfMigrationRecord -RunPath $rp -Reason 'waveClosed' | Out-Null
        }
        $global:RdFx = $script:fx
        Mock -ModuleName VmMigrationFactory Get-VmfMigrationRecordFromStore -ParameterFilter { $Reason -eq 'downloaded' } {
            $built = & $global:RdReal.Build @PesterBoundParameters
            # A restore keeps its record after the download read the store.
            InModuleScope VmMigrationFactory -Parameters @{ rp = $global:RdFx.Run } {
                New-VmfMigrationRecord -RunPath $rp -Reason 'putBack' | Out-Null
            }
            $built
        }
        { Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com' } | Should -Throw '409: *written again*'
        (Get-Content $script:fx.Kept -Raw | ConvertFrom-Json -Depth 32).reason | Should -Be 'putBack' -Because 'the newer record stays'
    }
}

Describe 'RECORD-DELETE-1 review 1: a delete that STOPPED after it kept its record' {
    BeforeEach {
        $script:fx = RdRun
        $script:deleteSays = '409: A delete of this migration started*'
    }
    AfterEach {
        if (Test-Path $script:fx.Store) { Remove-Item $script:fx.Store -Recurse -Force }
        Remove-Variable -Name RdCalls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'THE POINT: says so in the run history, and the download is allowed again and replaces the record' {
        Mock -ModuleName VmMigrationFactory Remove-VmfVmClaim { throw 'the store refused the claim release' }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'done' -RemovedBy 'operator@example.com' -KeepSafetyCopies -Confirm:$false } |
            Should -Throw '*refused the claim release*'
        Test-Path (Join-Path $script:fx.Run 'run.json') | Should -BeTrue -Because 'the migration is still there'
        (Get-Content $script:fx.Kept -Raw | ConvertFrom-Json -Depth 32).reason | Should -Be 'deleted'
        $stop = @(RdStopLines $script:fx.Run)
        $stop.Count | Should -Be 1
        $stop[0].detail | Should -Match 'stopped after it kept the record.*refused the claim release'
        (Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com').reason | Should -Be 'downloaded'
        (Get-Content $script:fx.Kept -Raw | ConvertFrom-Json -Depth 32).reason | Should -Be 'downloaded'
    }

    It 'the last reservation check refusing - a stop the delete was built to make - says so too' {
        $global:RdCalls = 0
        Mock -ModuleName VmMigrationFactory Assert-VmfNoBillingReservation {
            if (++$global:RdCalls -eq 3) { throw 'A capacity reservation for this migration bills.' }
        }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'done' -RemovedBy 'operator@example.com' -KeepSafetyCopies -Confirm:$false } |
            Should -Throw '*reservation*'
        @(RdStopLines $script:fx.Run).Count | Should -Be 1
        (Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com').reason | Should -Be 'downloaded'
    }

    It 'the engine''s failure line alone does NOT end it: the engine writes one after a removal that stopped part way' {
        # docker/entrypoint.ps1 writes engine:discard for any failure while
        # run.json is there, and in Azure run.json goes late in the removal.
        RdKeepDeletedRecord $script:fx.Run
        Start-Sleep -Milliseconds 20
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            Write-VmfEvent -RunPath $rp -Step 'engine:discard' -Outcome fail -Detail 'Store delete failed: HTTP 503'
        }
        { Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com' } | Should -Throw $script:deleteSays
    }

    It 'the engine path: a stop before the removal has the delete''s own line beside the engine''s, and is ended' {
        Mock -ModuleName VmMigrationFactory Remove-VmfVmClaim { throw 'the store refused the claim release' }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'done' -RemovedBy 'operator@example.com' -DeleteSafetyCopies -Confirm:$false } |
            Should -Throw '*refused the claim release*'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            Write-VmfEvent -RunPath $rp -Step 'engine:discard' -Outcome fail -Detail 'the store refused the claim release'
        }
        (Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com').reason | Should -Be 'downloaded'
    }

    It 'a failure line OLDER than the record does not end the delete that kept it' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            Write-VmfEvent -RunPath $rp -Step 'discard' -Outcome fail -Detail 'an earlier delete stopped'
        }
        Start-Sleep -Milliseconds 20
        RdKeepDeletedRecord $script:fx.Run
        { Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com' } | Should -Throw $script:deleteSays
    }

    It 'a removal that stopped part way writes no such line, so the half-removed run stays refused' {
        Mock -ModuleName VmMigrationFactory Remove-VmfStorePrefix { throw 'the store refused a delete' }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'done' -RemovedBy 'operator@example.com' -KeepSafetyCopies -Confirm:$false } |
            Should -Throw '*refused a delete*'
        @(RdStopLines $script:fx.Run).Count | Should -Be 0
        { Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com' } | Should -Throw $script:deleteSays
    }

    It 'a record whose time cannot be read is not taken as ended' {
        RdKeepDeletedRecord $script:fx.Run
        $doc = Get-Content $script:fx.Kept -Raw | ConvertFrom-Json -Depth 32
        $doc.generatedUtc = 'not a time'
        $doc | ConvertTo-Json -Depth 32 | Set-Content $script:fx.Kept
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            Write-VmfEvent -RunPath $rp -Step 'discard' -Outcome fail -Detail 'stopped'
        }
        { Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com' } | Should -Throw $script:deleteSays
    }

    It 'REVIEW 2, reproduced: a second delete that kept nothing does not end the record of a first delete that half removed the run' {
        # D1 keeps its record, then its removal stops part way: in Azure the
        # listing order removes logs/ and plan.json before run.json.
        RdKeepDeletedRecord $script:fx.Run
        $d1 = Get-Content $script:fx.Kept -Raw
        Remove-Item (Join-Path $script:fx.Run 'logs') -Recurse -Force
        Remove-Item (Join-Path $script:fx.Run 'plan.json') -Force
        # D2 finds run.json and no plan, so it keeps no record, and stops at
        # the last reservation check - inside the part that writes the stop line.
        $global:RdCalls = 0
        Mock -ModuleName VmMigrationFactory Assert-VmfNoBillingReservation {
            if (++$global:RdCalls -eq 3) { throw 'A capacity reservation for this migration bills.' }
        }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'again' -RemovedBy 'operator@example.com' -KeepSafetyCopies -Confirm:$false } |
            Should -Throw '*reservation*'
        $global:RdCalls | Should -Be 3 -Because 'D2 reached the last check'
        @(RdStopLines $script:fx.Run | Where-Object { $_.detail -match 'stopped after it kept' }).Count | Should -Be 0 -Because 'D2 kept nothing, so it says nothing about a kept record'
        { Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com' } | Should -Throw $script:deleteSays
        Get-Content $script:fx.Kept -Raw | Should -BeExactly $d1 -Because 'the record of D1 is never replaced from the half-removed run'
    }

    It 'a <Kind> after the record does not end it - it does not name the record' -ForEach @(
        @{ Kind = 'refusal before the keep (a reservation)'; Detail = 'The migration was not deleted, because an on-demand capacity reservation was made while its safety copies were deleted.'; Other = $false }
        @{ Kind = 'refusal before the keep (the migration changed)'; Detail = 'The migration was not deleted, because it changed while its safety copies were deleted.'; Other = $false }
        @{ Kind = 'service line (the engine did not start)'; Detail = 'The engine did not start, so nothing was deleted. The service said: HTTP 500'; Other = $false }
        @{ Kind = 'stop line that names another record'; Detail = 'The migration was not deleted, because the delete stopped after it kept the record of the migration.'; Other = $true }) {
        RdKeepDeletedRecord $script:fx.Run
        Start-Sleep -Milliseconds 20
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; d = $Detail; o = $Other } {
            if ($o) { Write-VmfEvent -RunPath $rp -Step 'discard' -Outcome fail -Detail $d -Data @{ keptRecordUtc = '2026-01-01T00:00:00.0000000Z' } }
            else { Write-VmfEvent -RunPath $rp -Step 'discard' -Outcome fail -Detail $d }
        }
        { Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com' } | Should -Throw $script:deleteSays
    }

    It 'with no plan.json the run is not whole, whatever the stop line says' {
        Mock -ModuleName VmMigrationFactory Remove-VmfVmClaim { throw 'the store refused the claim release' }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'done' -RemovedBy 'operator@example.com' -KeepSafetyCopies -Confirm:$false } |
            Should -Throw '*refused the claim release*'
        @(RdStopLines $script:fx.Run).Count | Should -Be 1 -Because 'a line that names the record'
        Remove-Item (Join-Path $script:fx.Run 'plan.json') -Force
        { Export-VmfMigrationRecord -RunPath $script:fx.Run -GeneratedBy 'admin@example.com' } | Should -Throw $script:deleteSays
    }

    It 'the service asks the same one rule for an open delete' {
        $events = @(
            [pscustomobject]@{ step = 'discard'; outcome = 'start' }
            [pscustomobject]@{ step = 'engine:discard'; outcome = 'fail' }
            [pscustomobject]@{ step = 'discard'; outcome = 'start'; detail = 'second' })
        (InModuleScope FacadeCore -Parameters @{ ev = $events } { Get-VmfFacadeOpenDiscard -Events $ev }).detail | Should -Be 'second'
        InModuleScope FacadeCore -Parameters @{ ev = @($events[0], $events[1]) } { Get-VmfFacadeOpenDiscard -Events $ev } | Should -BeNullOrEmpty
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $code | Should -Match 'Get-VmfOpenDiscard -Events'
    }
}

Describe 'RECORD-DELETE-1: in Azure storage, where the check and the keep are one request' {
    # Every test above uses a local folder. ATTEST-1 found on the first Azure
    # install that records written to a local folder in every test were never
    # written in Azure. These run the download against a store that answers
    # the way blob storage does: an ETag on every read, If-Match and
    # If-None-Match honoured on every write.
    BeforeEach {
        $global:RdBlobs = @{}
        $global:RdTags = @{}
        $global:RdSerial = 0
        $global:RdOnSecondRecordRead = $null
        $global:RdRecordReads = 0
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $u = [uri]$Uri
            $path = [uri]::UnescapeDataString($u.AbsolutePath.TrimStart([char]0x2F))
            $query = $u.Query
            $h = if ($Headers) { $Headers } else { @{} }
            if ($Method -eq 'GET' -and $query -match 'comp=list') {
                $prefix = if ($query -match 'prefix=([^&]*)') { [uri]::UnescapeDataString($Matches[1]) } else { '' }
                $container = ($path -split '/')[0]
                $names = @($global:RdBlobs.Keys | Where-Object { $_.StartsWith("$container/$prefix") } |
                    ForEach-Object { $_.Substring($container.Length + 1) })
                $xml = '<EnumerationResults><Blobs>' + (($names | ForEach-Object { "<Blob><Name>$_</Name></Blob>" }) -join '') + '</Blobs><NextMarker /></EnumerationResults>'
                return @{ StatusCode = 200; Content = $xml; Headers = @{} }
            }
            switch ($Method) {
                'PUT' {
                    $there = $global:RdBlobs.ContainsKey($path)
                    if ($h['If-None-Match'] -eq '*' -and $there) { return @{ StatusCode = 409; Content = 'BlobAlreadyExists'; Headers = @{} } }
                    if ($h['If-Match'] -and (-not $there -or $global:RdTags[$path] -ne $h['If-Match'])) { return @{ StatusCode = 412; Content = 'ConditionNotMet'; Headers = @{} } }
                    $global:RdBlobs[$path] = [string]$Body
                    $global:RdTags[$path] = '"t' + (++$global:RdSerial) + '"'
                    return @{ StatusCode = 201; Content = ''; Headers = @{ ETag = $global:RdTags[$path] } }
                }
                'DELETE' { $global:RdBlobs.Remove($path); return @{ StatusCode = 202; Content = ''; Headers = @{} } }
                'HEAD' { return @{ StatusCode = $(if ($global:RdBlobs.ContainsKey($path)) { 200 } else { 404 }); Content = ''; Headers = @{} } }
                default {
                    if (-not $global:RdBlobs.ContainsKey($path)) { return @{ StatusCode = 404; Content = ''; Headers = @{} } }
                    $answer = @{ StatusCode = 200; Content = $global:RdBlobs[$path]; Headers = @{ ETag = $global:RdTags[$path] } }
                    if ($path -like 'vmf-runs/vmf-records/*') {
                        $global:RdRecordReads++
                        # The delete keeps its record AFTER this read was answered. Read 1 is the version before the build, read 2 the check after it, read 3 the store's own read before its PUT.
                        if ($global:RdRecordReads -eq 3 -and $global:RdOnSecondRecordRead) { & $global:RdOnSecondRecordRead $path }
                    }
                    return $answer
                }
            }
        }
        $global:RdBlobs['vmf-runs/mig-2/run.json'] = (@{ schemaVersion = 1; runId = 'mig-2'; kind = 'migration'; createdUtc = '2026-09-24T09:00:00Z' } | ConvertTo-Json)
        $global:RdTags['vmf-runs/mig-2/run.json'] = '"t0"'
        $global:RdBlobs['vmf-runs/mig-2/plan.json'] = (@{ schemaVersion = 1; assessmentRunId = 'scan-1'; entries = @() } | ConvertTo-Json)
        $global:RdTags['vmf-runs/mig-2/plan.json'] = '"t0"'
        $script:azRun = 'azblob://acct/vmf-runs/mig-2'
        $script:keptBlob = 'vmf-runs/vmf-records/mig-2.json'
    }
    AfterEach {
        Remove-Variable -Name RdBlobs, RdTags, RdSerial, RdOnSecondRecordRead, RdRecordReads -Scope Global -ErrorAction SilentlyContinue
    }

    It 'the first download creates the record, and the next one replaces it' {
        Export-VmfMigrationRecord -RunPath $script:azRun -GeneratedBy 'admin@example.com' | Out-Null
        ($global:RdBlobs[$script:keptBlob] | ConvertFrom-Json -Depth 32).generatedBy | Should -Be 'admin@example.com'
        Export-VmfMigrationRecord -RunPath $script:azRun -GeneratedBy 'other@example.com' | Out-Null
        ($global:RdBlobs[$script:keptBlob] | ConvertFrom-Json -Depth 32).generatedBy | Should -Be 'other@example.com'
    }

    It 'refuses when the record a delete kept is there' {
        $global:RdBlobs[$script:keptBlob] = (@{ schemaVersion = 3; runId = 'mig-2'; reason = 'deleted' } | ConvertTo-Json)
        $global:RdTags[$script:keptBlob] = '"t-del"'
        { Export-VmfMigrationRecord -RunPath $script:azRun -GeneratedBy 'admin@example.com' } | Should -Throw '409: A delete of this migration started*'
        ($global:RdBlobs[$script:keptBlob] | ConvertFrom-Json).reason | Should -Be 'deleted'
    }

    It 'THE POINT: a delete that keeps its record between the version check and the write - the write is refused by the store' {
        Export-VmfMigrationRecord -RunPath $script:azRun -GeneratedBy 'admin@example.com' | Out-Null
        $global:RdRecordReads = 0
        $global:RdOnSecondRecordRead = {
            param($p)
            $global:RdBlobs[$p] = (@{ schemaVersion = 3; runId = 'mig-2'; reason = 'deleted' } | ConvertTo-Json)
            $global:RdTags[$p] = '"t-del"'
        }
        { Export-VmfMigrationRecord -RunPath $script:azRun -GeneratedBy 'other@example.com' } | Should -Throw '409: *'
        ($global:RdBlobs[$script:keptBlob] | ConvertFrom-Json).reason | Should -Be 'deleted' -Because 'the record the delete kept stays'
    }
}

Describe 'RECORD-DELETE-1: the service refuses the download while the engine deletes the migration' {
    BeforeAll {
        $script:admin = [pscustomobject]@{ Identity = 'admin@example.com'; Roles = @('Vmf.Admin') }
    }
    BeforeEach {
        $script:fx = RdRun
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.App/jobs/engine')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            Write-VmfEvent -RunPath $rp -Step 'discard' -Outcome start -Detail 'operator@example.com started to delete this migration'
        }
    }
    AfterEach {
        if (Test-Path $script:fx.Store) { Remove-Item $script:fx.Store -Recurse -Force }
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', $null)
    }

    It 'THE POINT: refused while the delete is open and Azure lists its job, before anything is read or kept' {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { (@($Operation) -contains 'discard') -and $RunId -eq 'mig-1' }
        { Invoke-VmfFacadeExportMigrationRecord -Principal $script:admin -StorePath $script:fx.Run } |
            Should -Throw '409: *being deleted*'
        Test-Path $script:fx.Kept | Should -BeFalse
        @(RdRecordLines $script:fx.Run).Count | Should -Be 0
    }

    It 'the refusal is a sentence about the download, not the one for a restore or a wave' {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $true }
        try { Invoke-VmfFacadeExportMigrationRecord -Principal $script:admin -StorePath $script:fx.Run; throw 'not refused' }
        catch { $msg = $_.Exception.Message }
        $msg | Should -Match 'record'
        $msg | Should -Not -Match 'Nothing else can start'
    }

    It 'allowed once the delete has ended in the log (a delete that failed), without asking Azure' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run } {
            Write-VmfEvent -RunPath $rp -Step 'engine:discard' -Outcome fail -Detail '1 of 3 safety copies were not deleted'
        }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { throw 'no need to ask Azure' }
        (Invoke-VmfFacadeExportMigrationRecord -Principal $script:admin -StorePath $script:fx.Run).reason | Should -Be 'downloaded'
    }

    It 'allowed when Azure lists no delete job (one the platform stopped)' {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        (Invoke-VmfFacadeExportMigrationRecord -Principal $script:admin -StorePath $script:fx.Run).reason | Should -Be 'downloaded'
    }

    It 'the other actions keep their own refusal' {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $true }
        Mock -ModuleName FacadeCore Resolve-VmfDecision { throw 'reached the retry' }
        { Invoke-VmfFacadeResolve -Principal ([pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }) `
            -StorePath $script:fx.Run -VmId $script:fx.Vm -Note 'n' } | Should -Throw '400: *Nothing else can start*'
    }
}

Describe 'RECORD-DELETE-1: the endpoint answers a refusal as a conflict' {
    It 'POST /record maps 409 to Conflict, not to a server fault' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostMigrationRecord' 'run.ps1')
        $code | Should -Match "\`$_ -match '\^409'\) \{ \[HttpStatusCode\]::Conflict \}"
    }
}
