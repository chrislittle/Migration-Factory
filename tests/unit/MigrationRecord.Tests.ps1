#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
ATTEST-1: a full record of every migration, to keep.

A customer asked at the first demo for a full log with results, in a good
format for attestation. Ruled 2026-09-24: for the
Administrator role (engineering and change management); correct data, not
tamper-proofing; kept 90 days to download, including after the migration is
deleted.

The facts were already in the store, in three places, with nothing putting
them together - and a delete removed all three.
#>
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:schema = Join-Path $script:repo 'schemas' 'migration-record.schema.json'

    # A migration with two machines: one migrated, one put back. Built through
    # the engine's own functions, so the documents are the shapes it writes.
    function Global:RecordRun {
        param([string]$Root, [string]$Project)
        if ($Project) {
            New-VmfProject -StorePath $Root -ProjectId $Project -Name $Project `
                -OnBehalfOf @{ Identity = 'sam@example.com'; TenantId = 't1' } | Out-Null
        }
        $rp = if ($Project) { "$Root/$Project/mig-1" } else { "$Root/mig-1" }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; pr = $Project } {
            Initialize-VmfRun -RunPath $rp -RunId 'mig-1' -Kind 'migration' -FromAssessment 'scan-1' -Project $pr | Out-Null
            foreach ($n in 'web', 'db') {
                $id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$n"
                New-VmfStateDoc -RunPath $rp -RunId 'mig-1' -VmId $id -Wave 'w1' | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'PRECHECK' -Outcome ok | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok -Detail 'passed validation' | Out-Null
                Write-VmfEvent -RunPath $rp -Step 'azureops:deallocate' -Outcome ok -VmId $id
            }
            $db = Read-VmfStateDoc -RunPath $rp -VmId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/db'
            $db | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{
                # STATUS-WORDS-1: the restore comes after the move it undoes; a
                # restore older than the newest step is a machine that moved again.
                restoredUtc = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o'); restoredBy = 'operator@example.com'; sizeAfter = 'Standard_D2s_v4' }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $db | Out-Null
            Write-VmfEvent -RunPath $rp -Step 'approval' -Outcome ok -Detail 'the plan was signed off'
        }
        @{ schemaVersion = 1; assessmentRunId = 'scan-1'; entries = @(foreach ($n in 'web', 'db') {
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$n"
               wave = 'w1'; path = 'A'; assessment = @{ sourceSize = 'Standard_D2s_v4'; os = 'Windows Server 2022' }
               target = @{ size = 'Standard_D2s_v6'; controller = 'NVMe' } } }) } |
            ConvertTo-Json -Depth 8 | Set-Content (Join-Path $rp 'plan.json')
        @{ schemaVersion = 1; runId = 'scan-1'; waves = @('w1'); approvedBy = @{ identity = 'approver@example.com'; tenantId = $null }
           approvedUtc = '2026-09-23T15:10:00Z'; planHash = ('a' * 64); note = 'reviewed' } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $rp 'plan-approval.json')
        $rp
    }
    function Global:RecordOperator {
        param([string[]]$Roles)
        $claims = @(@{ typ = 'preferred_username'; val = 'person@example.com' }) + @($Roles | ForEach-Object { @{ typ = 'roles'; val = $_ } })
        $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
        ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
    }
}
AfterAll { Remove-Item 'function:\RecordRun', 'function:\RecordOperator' -ErrorAction SilentlyContinue }

Describe 'ATTEST-1: the record' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rec-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force } }

    It 'is what the contract says, and is kept beside the runs for 90 days' {
        $rp = RecordRun $script:root
        $r = Export-VmfMigrationRecord -RunPath $rp -GeneratedBy 'admin@example.com'
        $file = Join-Path $script:root 'vmf-records' 'mig-1.json'
        Test-Path $file | Should -BeTrue
        Get-Content $file -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
        $r.generatedBy | Should -Be 'admin@example.com'
        $r.reason | Should -Be 'downloaded'
        # As instants, not local clock times: a daylight-saving change inside the
        # 90 days made a local subtraction read 89.96.
        ([datetimeoffset]$r.keepUntilUtc - [datetimeoffset]$r.generatedUtc).TotalDays | Should -Be 90
    }

    It 'counts by the one definition, and says where each "now" figure came from' {
        $r = Export-VmfMigrationRecord -RunPath (RecordRun $script:root) -GeneratedBy 'admin@example.com'
        $r.summary.migrated | Should -Be 1
        $r.summary.putBack | Should -Be 1
        $web = $r.machines | Where-Object name -EQ 'web'
        $db = $r.machines | Where-Object name -EQ 'db'
        $web.now.size | Should -Be 'Standard_D2s_v6'
        $web.now.basis | Should -Match 'plan target'
        $db.outcome | Should -Be 'putBack'
        $db.now.size | Should -Be 'Standard_D2s_v4'
        $db.now.basis | Should -Match 'restore record'
        $db.putBack.restoredBy | Should -Be 'operator@example.com'
    }

    It 'FINISH-COUNT-1: a restore that left a data disk swap waits for a person, and its "now" figure is still the restore record' {
        $rp = RecordRun $script:root
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
            $id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/db'
            Set-VmfSwapPending -RunPath $rp -VmId $id -Record (New-VmfSwapPendingRecord -Kind 'restore' -Reason 'refused' `
                -Swaps @([ordered]@{ lun = 0; name = 'db-d0'; diskId = '/s/rg/disks/db-d0-r'; diskName = 'db-d0-r' }))
        }
        $r = Export-VmfMigrationRecord -RunPath $rp -GeneratedBy 'admin@example.com'
        Get-Content (Join-Path $script:root 'vmf-records' 'mig-1.json') -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
        $r.summary.putBack | Should -Be 0 -Because 'the machine is stopped until Finish the restore'
        $r.summary.attention | Should -Be 1
        $db = $r.machines | Where-Object name -EQ 'db'
        $db.outcome | Should -Be 'attention'
        $db.now.size | Should -Be 'Standard_D2s_v4' -Because 'the restore put the size back before the swap was refused'
        $db.now.basis | Should -Match 'restore record'
    }

    It 'every step, and every activity line, lands on the machine it is about' {
        $r = Export-VmfMigrationRecord -RunPath (RecordRun $script:root) -GeneratedBy 'admin@example.com'
        $web = $r.machines | Where-Object name -EQ 'web'
        @($web.steps.state) -join ',' | Should -Match 'PRECHECK,MIGRATED'
        @($web.activity | Where-Object step -EQ 'azureops:deallocate').Count | Should -Be 1
        @($r.runActivity | Where-Object step -EQ 'approval').Count | Should -Be 1 -Because 'a line about no machine is the run''s'
    }

    It 'names who signed the plan off, with the version they signed' {
        $r = Export-VmfMigrationRecord -RunPath (RecordRun $script:root) -GeneratedBy 'admin@example.com'
        $d = @($r.decisions | Where-Object what -EQ 'signed off the plan')
        $d.Count | Should -Be 1
        $d[0].by | Should -Be 'approver@example.com'
        $d[0].version | Should -Be ('a' * 64)
    }

    It 'WAVE-APPROVE-1: a wave approval records the version of its wave, and one written by the sign-off says so' {
        $rp = RecordRun $script:root
        Remove-Item (Join-Path $rp 'plan-approval.json')
        Approve-VmfPlan -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Note 'every wave read' `
            -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = $null } | Out-Null
        $r = Export-VmfMigrationRecord -RunPath $rp -GeneratedBy 'admin@example.com'
        $w = @($r.decisions | Where-Object { $_.wave -eq 'w1' -and $_.what -like 'approved the wave*' })
        $w.Count | Should -Be 1
        $w[0].what | Should -Be 'approved the wave by signing off the plan'
        $w[0].version | Should -BeExactly (InModuleScope VmMigrationFactory -Parameters @{ t = (Get-Content (Join-Path $rp 'plan.json') -Raw) } { Get-VmfWaveVersion -PlanText $t -Wave 'w1' })
        # Approved again later, by another person: an approval of its own.
        Approve-VmfWave -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Wave 'w1' -Note 'again' `
            -OnBehalfOf @{ Identity = 'second@example.com'; TenantId = $null } | Out-Null
        $r = Export-VmfMigrationRecord -RunPath $rp -GeneratedBy 'admin@example.com'
        @($r.decisions | Where-Object { $_.wave -eq 'w1' -and $_.what -like 'approved the wave*' })[0].what | Should -Be 'approved the wave'
    }

    It 'a run inside a project keeps its record in the SAME folder as every other' {
        $rp = RecordRun $script:root -Project 'estate'
        Export-VmfMigrationRecord -RunPath $rp -GeneratedBy 'admin@example.com' | Out-Null
        Test-Path (Join-Path $script:root 'vmf-records' 'estate--mig-1.json') | Should -BeTrue
        @(Get-VmfMigrationRecord -StorePath $script:root).Name | Should -Contain 'estate--mig-1.json'
    }
}

Describe 'ATTEST-1: it outlives the migration' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rec-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force } }

    It 'deleting a migration writes its record first, and the record survives the delete' {
        $rp = RecordRun $script:root
        Remove-VmfRun -RunPath $rp -Reason 'done' -RemovedBy 'operator@example.com' -KeepSafetyCopies -Confirm:$false | Out-Null
        Test-Path $rp | Should -BeFalse -Because 'the migration is gone'
        $kept = Get-VmfMigrationRecord -StorePath $script:root -Name 'mig-1.json'
        $kept.reason | Should -Be 'deleted'
        $kept.generatedBy | Should -Be 'operator@example.com'
        @($kept.machines).Count | Should -Be 2
    }

    It 'a delete that cannot keep the record deletes nothing' {
        $rp = RecordRun $script:root
        Mock -ModuleName VmMigrationFactory New-VmfMigrationRecord { throw 'the store refused the write' }
        { Remove-VmfRun -RunPath $rp -Reason 'done' -RemovedBy 'operator@example.com' -KeepSafetyCopies -Confirm:$false } |
            Should -Throw '*could not be kept, so nothing was deleted*'
        Test-Path (Join-Path $rp 'plan.json') | Should -BeTrue
    }

    It 'the daily cleanup removes a record past its 90 days, and keeps one it cannot date' {
        $rp = RecordRun $script:root
        Export-VmfMigrationRecord -RunPath $rp -GeneratedBy 'admin@example.com' | Out-Null
        $file = Join-Path $script:root 'vmf-records' 'mig-1.json'
        $gone = InModuleScope VmMigrationFactory -Parameters @{ r = $script:root } {
            Remove-VmfExpiredMigrationRecords -StorePath $r -AsOf (Get-Date).ToUniversalTime().AddDays(89) }
        @($gone).Count | Should -Be 0 -Because 'day 89 is inside the 90'
        $undated = Join-Path $script:root 'vmf-records' 'odd.json'
        '{ "runId": "odd", "keepUntilUtc": "not a date" }' | Set-Content $undated
        $gone = InModuleScope VmMigrationFactory -Parameters @{ r = $script:root } {
            Remove-VmfExpiredMigrationRecords -StorePath $r -AsOf (Get-Date).ToUniversalTime().AddDays(91) }
        @($gone.Name) | Should -Be @('mig-1.json')
        Test-Path $file | Should -BeFalse
        Test-Path $undated | Should -BeTrue -Because 'unknown is not old'
    }

    It 'a record name is a file name in the records folder, never a path' {
        { Get-VmfMigrationRecord -StorePath $script:root -Name '../mig-1/plan.json' } | Should -Throw '400:*'
        { Get-VmfMigrationRecord -StorePath $script:root -Name 'missing.json' } | Should -Throw '404:*'
    }
}

Describe 'ATTEST-1: in Azure storage, not only on a local disk' {
    # FOUND ON THE FIRST AZURE INSTALL, 2026-09-24. Every test above uses a
    # local folder, where "vmf-records/<name>" under the store root is just a
    # folder. In Azure the root is a bare container, the store refuses that as
    # a run path, and so the record was never written after a wave, both
    # downloads failed, and deleting a migration stopped. These run the same
    # functions against a store addressed the way Azure addresses it.
    BeforeEach {
        $global:VmfFakeBlobs = @{}
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $u = [uri]$Uri
            $path = [uri]::UnescapeDataString($u.AbsolutePath.TrimStart([char]0x2F))
            $query = $u.Query
            if ($Method -eq 'GET' -and $query -match 'comp=list') {
                $prefix = if ($query -match 'prefix=([^&]*)') { [uri]::UnescapeDataString($Matches[1]) } else { '' }
                $container = ($path -split '/')[0]
                $names = @($global:VmfFakeBlobs.Keys | Where-Object { $_.StartsWith("$container/$prefix") } |
                    ForEach-Object { $_.Substring($container.Length + 1) })
                $xml = '<EnumerationResults><Blobs>' + (($names | ForEach-Object { "<Blob><Name>$_</Name></Blob>" }) -join '') + '</Blobs><NextMarker /></EnumerationResults>'
                return @{ StatusCode = 200; Content = $xml; Headers = @{} }
            }
            switch ($Method) {
                'PUT' { $global:VmfFakeBlobs[$path] = [string]$Body; return @{ StatusCode = 201; Content = ''; Headers = @{} } }
                'DELETE' { $global:VmfFakeBlobs.Remove($path); return @{ StatusCode = 202; Content = ''; Headers = @{} } }
                'HEAD' { return @{ StatusCode = $(if ($global:VmfFakeBlobs.ContainsKey($path)) { 200 } else { 404 }); Content = ''; Headers = @{} } }
                default {
                    if ($global:VmfFakeBlobs.ContainsKey($path)) { return @{ StatusCode = 200; Content = $global:VmfFakeBlobs[$path]; Headers = @{} } }
                    return @{ StatusCode = 404; Content = ''; Headers = @{} }
                }
            }
        }
        $script:azRoot = 'azblob://acct/vmf-runs'
        $recordDoc = @{ schemaVersion = 1; runId = 'mig-1'; project = 'estate'; generatedUtc = '2026-09-24T10:00:00Z'
                        reason = 'waveClosed'; keepUntilUtc = '2026-12-23T10:00:00Z' } | ConvertTo-Json
        $global:VmfFakeBlobs['vmf-runs/vmf-records/estate--mig-1.json'] = $recordDoc
    }
    AfterEach { Remove-Variable -Name VmfFakeBlobs -Scope Global -ErrorAction SilentlyContinue }

    It 'the records folder is a store path Azure storage accepts, for a run in a project and one outside' {
        InModuleScope VmMigrationFactory {
            foreach ($run in @(@{ p = 'azblob://acct/vmf-runs/estate/mig-1'; pr = 'estate' }, @{ p = 'azblob://acct/vmf-runs/mig-1'; pr = '' })) {
                $root = Get-VmfStoreRootOf -RunPath $run.p -Project $run.pr
                $scope = Get-VmfRecordScope -StorePath $root
                $scope | Should -Be 'azblob://acct/vmf-runs/vmf-records'
                { Get-VmfStoreContext -RunPath $scope } | Should -Not -Throw
            }
        }
    }

    It 'lists, reads and expires the records kept in Azure' {
        @(Get-VmfMigrationRecord -StorePath $script:azRoot).Name | Should -Be @('estate--mig-1.json')
        (Get-VmfMigrationRecord -StorePath $script:azRoot -Name 'estate--mig-1.json').runId | Should -Be 'mig-1'
        $gone = InModuleScope VmMigrationFactory -Parameters @{ r = $script:azRoot } {
            Remove-VmfExpiredMigrationRecords -StorePath $r -AsOf ([datetime]'2027-01-01') }
        @($gone.Name) | Should -Be @('estate--mig-1.json')
        $global:VmfFakeBlobs.ContainsKey('vmf-runs/vmf-records/estate--mig-1.json') | Should -BeFalse
    }

    It 'writes the record for a migration kept in Azure' {
        $run = 'vmf-runs/estate/mig-2'
        $global:VmfFakeBlobs["$run/run.json"] = (@{ schemaVersion = 1; runId = 'mig-2'; kind = 'migration'; project = 'estate'; createdUtc = '2026-09-24T09:00:00Z' } | ConvertTo-Json)
        $global:VmfFakeBlobs["$run/plan.json"] = (@{ schemaVersion = 1; assessmentRunId = 'scan-1'; entries = @() } | ConvertTo-Json)
        InModuleScope VmMigrationFactory {
            New-VmfMigrationRecord -RunPath 'azblob://acct/vmf-runs/estate/mig-2' -Reason 'waveClosed' | Out-Null
        }
        $global:VmfFakeBlobs.ContainsKey('vmf-runs/vmf-records/estate--mig-2.json') | Should -BeTrue
    }

    It 'the daily cleanup can leave its own record at the top of an Azure store' {
        InModuleScope VmMigrationFactory {
            Write-VmfStoreRootJson -StorePath 'azblob://acct/vmf-runs' -Name 'retention-status.json' -Document @{ schemaVersion = 1 }
            { Write-VmfStoreRootJson -StorePath 'azblob://acct/vmf-runs' -Name 'vmf-records/x.json' -Document @{} } | Should -Throw '*not a document name*'
        }
        $global:VmfFakeBlobs.ContainsKey('vmf-runs/retention-status.json') | Should -BeTrue
        (Get-Content (Join-Path $script:repo 'src' 'facade' 'app' 'RetentionRunner' 'run.ps1') -Raw) |
            Should -Match "Write-VmfStoreRootJson -StorePath \`$r -Name 'retention-status.json'"
    }
}

Describe 'ATTEST-1: for the Administrator role' {
    It 'an operator or an approver is refused, an administrator is not' {
        foreach ($role in 'Vmf.Operator', 'Vmf.Approver', 'Vmf.Viewer') {
            { Invoke-VmfFacadeListMigrationRecords -Principal (RecordOperator -Roles $role) } | Should -Throw '403*'
            { Invoke-VmfFacadeExportMigrationRecord -Principal (RecordOperator -Roles $role) -StorePath 'x' } | Should -Throw '403*'
            { Invoke-VmfFacadeGetKeptMigrationRecord -Principal (RecordOperator -Roles $role) -Name 'x.json' } | Should -Throw '403*'
        }
    }

    # REPORT-AUTO-1: the record is kept with the report, by one function that
    # never throws and says a failure in the run history. ReportAuto.Tests.ps1
    # runs it; this holds the wave's call to it in place.
    It 'the engine writes the record when a wave closes out, and a failure there does not fail the wave' {
        $entry = Get-Content (Join-Path $script:repo 'docker' 'entrypoint.ps1') -Raw
        $entry | Should -Match "Invoke-VmfWaveCloseOut -RunPath \`$runPath -Wave \`$env:VMF_WAVE -Result \`$r\s+# ATTEST-1"
        $entry | Should -Match "Save-VmfRecordAndReport -RunPath \`$rp -Reason 'waveClosed'"
        $code = Get-Content (Join-Path $script:repo 'src' 'VmMigrationFactory' 'Private' 'report' 'RecordAndReport.ps1') -Raw
        $code | Should -Match "& \`$warn 'record'"
    }

    It 'the daily cleanup expires records' {
        (Get-Content (Join-Path $script:repo 'src' 'facade' 'app' 'RetentionRunner' 'run.ps1') -Raw) |
            Should -Match 'Remove-VmfExpiredMigrationRecords -StorePath \$r'
    }
}
