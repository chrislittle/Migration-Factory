#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
REPORT-AUTO-1: the report is written by itself, and there is one kind.

Decided 2026-10-02. Before this, a migration had a report only
when somebody pressed "Produce the report" and chose who it was for; the
engineering kind went to report.html, which the Reports page never opens.

  - The engine writes the report when a wave finishes and when a machine is
    restored or rebuilt - at the same moments as the migration record, from
    the same record, so the two never disagree.
  - A failure to write it never fails the wave or the restore: it is an event
    the run history shows, and the next trigger writes it again.
  - Writing twice gives the same file.
  - One report: no audience, no appendix, never report.html. Every fact only
    the appendix held is in the migration record now (v3).
#>
BeforeAll {
    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repo 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:schema = Join-Path $script:repo 'schemas' 'migration-record.schema.json'

    # A migration with three machines, built through the engine's own
    # functions: web migrated on Path B with a checkpoint, db not started and
    # planned with alternates and a note, and app left MANUAL although the
    # scan called it ready. One quota record. The values differ on purpose, so
    # a reader that takes one machine's fact for another's is caught.
    function Global:RaRun {
        param([string]$Root)
        $rp = Join-Path $Root 'mig-auto'
        # Spelled here: a function made global does not see this file's script scope.
        $sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; sub = $sub } {
            param($rp, $sub)
            Initialize-VmfRun -RunPath $rp -RunId 'mig-auto' -Kind 'migration' -FromAssessment 'scan-auto' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'mig-auto' -VmId "${sub}web" -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId "${sub}web" -NewState 'PRECHECK' -Outcome ok | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId "${sub}web" -NewState 'MIGRATED' -Outcome ok -Detail 'passed validation' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId "${sub}web"
            $doc | Add-Member -NotePropertyName pathCheckpoint -NotePropertyValue 'B:recreated' -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc | Out-Null
        }
        @{
            schemaVersion = 17; runId = 'scan-auto'; generatedUtc = '2026-10-01T08:00:00Z'
            scope = @{ subscriptions = @('s') }
            summary = @{ ReadyAfterPrep = 2; Blocked = 1 }
            vms = @(
                @{ vmId = "${sub}web"; name = 'web'; classification = 'ReadyAfterPrep'; os = 'Windows'; gen = 'V2'
                   sourceSize = 'Standard_D4ds_v4'; sourceDiskArch = 'scsi-temp'; blockers = @(); prepNeeded = @('stornvme', 'pagefile'); notes = @() },
                @{ vmId = "${sub}db"; name = 'db'; classification = 'Blocked'; os = 'Linux'; gen = 'V1'
                   sourceSize = 'Standard_E2s_v4'; sourceDiskArch = 'diskless'; blockers = @('gen1-requires-redeploy'); prepNeeded = @('linux-nvme-prep'); notes = @() },
                @{ vmId = "${sub}app"; name = 'app'; classification = 'ReadyAfterPrep'; os = 'Linux'; gen = 'V2'
                   sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; blockers = @(); prepNeeded = @(); notes = @() }
            )
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $rp 'assessment.json')
        @{ schemaVersion = 1; assessmentRunId = 'scan-auto'; entries = @(
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "${sub}web"; wave = 'w1'; path = 'B'; policy = @{ targetGeneration = 'v6' }; assessment = @{ sourceSize = 'Standard_D4ds_v4'; os = 'Windows' }
               target = @{ size = 'Standard_D4ds_v6'; controller = 'NVMe'; sizeAlternates = @('Standard_D4ads_v6') }; planNotes = @('rebuilt around the same disks') },
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "${sub}db"; wave = 'w2'; path = 'A'; policy = @{ targetGeneration = 'v5' }; assessment = @{ sourceSize = 'Standard_E2s_v4'; os = 'Linux' }
               target = @{ size = 'Standard_E2s_v5'; controller = 'SCSI'; sizeAlternates = @('Standard_E2as_v5', 'Standard_E2ds_v5') }; planNotes = @('check the initramfs') },
            @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "${sub}app"; wave = 'unscheduled'; path = 'MANUAL'; policy = @{ targetGeneration = 'v6' }; assessment = @{ sourceSize = 'Standard_D2s_v4'; os = 'Linux' }
               # BSV2-NOTES-1: a plan written before SIZEMAP-REMOVE-1 (2026-10-16) can hold one empty alternate.
               target = @{ size = $null; sizeAlternates = @('') }; planNotes = @('No target was chosen for this machine, so it is not moved.') }
        ) } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $rp 'plan.json')
        New-Item -ItemType Directory -Path (Join-Path $rp 'capacity') -Force | Out-Null
        @{
            schemaVersion = 1; runId = 'mig-auto'; wave = 'w1'; region = 'centralus'; zone = '2'
            size = 'Standard_D4ds_v6'; vmFamily = 'standardDDSv6Family'; state = 'QUOTA_VERIFIED'; blockReason = $null
            demand = @{ instances = 1; vcpus = 4; overlapWithSource = $false }
            quota = @{ limit = 40; used = 12; requestId = $null; requestedUtc = $null }
            notes = @('family read from the usage list')
        } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $rp 'capacity' 'w1-centralus.json')
        @{ schemaVersion = 1; runId = 'scan-auto'; waves = @('w1', 'w2'); approvedBy = @{ identity = 'approver@example.com'; tenantId = $null }
           approvedUtc = '2026-10-01T09:00:00Z'; planHash = ('b' * 64); note = 'reviewed' } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $rp 'plan-approval.json')
        $rp
    }
    function Global:RaEvents([string]$RunPath, [string]$Step) {
        $log = Join-Path $RunPath 'logs' 'events.jsonl'
        if (-not (Test-Path $log)) { return @() }
        @(Get-Content $log | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.step -eq $Step })
    }
}
AfterAll { Remove-Item 'function:\RaRun', 'function:\RaEvents' -ErrorAction SilentlyContinue }

Describe 'REPORT-AUTO-1: the engine keeps the record and writes the report together' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rauto-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:rp = RaRun $script:root
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force } }

    It 'writes the record AND the report, and the record says why it was written' {
        foreach ($why in 'waveClosed', 'putBack') {
            $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; why = $why } { param($rp, $why) Save-VmfRecordAndReport -RunPath $rp -Reason $why }
            $r.record | Should -BeTrue -Because "$why keeps the record"
            $r.report | Should -BeTrue -Because "$why writes the report"
            $kept = Get-Content (Join-Path $script:root 'vmf-records' 'mig-auto.json') -Raw
            ($kept | ConvertFrom-Json).reason | Should -Be $why
            $kept | Test-Json -SchemaFile $script:schema | Should -BeTrue -Because "a record written for $why is what the contract says"
        }
        Test-Path (Join-Path $script:rp 'customer-report.html') | Should -BeTrue
        Test-Path (Join-Path $script:rp 'report.html') | Should -BeFalse -Because 'there is one report, and it is the one the Reports page opens'
    }

    It 'the report is rendered from the record that was just kept, so the two never disagree' {
        $script:seen = $null
        Mock -ModuleName VmMigrationFactory New-VmfReport { $script:seen = $Record; 'x' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
        $kept = Get-Content (Join-Path $script:root 'vmf-records' 'mig-auto.json') -Raw
        $script:seen | Should -Not -BeNullOrEmpty -Because 'the record goes to the report, rather than the report building a second one'
        $kept | Should -Match ('"generatedUtc":\s*"' + [regex]::Escape([string]$script:seen.generatedUtc) + '"') -Because 'it is the same record, to the tick'
    }

    It 'a report that cannot be written does not throw, keeps the record, and says so in the run history' {
        Mock -ModuleName VmMigrationFactory New-VmfReport { throw 'the store refused the report' }
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'putBack' }
        $r.report | Should -BeFalse
        $r.record | Should -BeTrue
        Test-Path (Join-Path $script:root 'vmf-records' 'mig-auto.json') | Should -BeTrue
        $ev = @(RaEvents $script:rp 'report' | Where-Object outcome -EQ 'warn')
        $ev.Count | Should -Be 1
        $ev[0].detail | Should -Match 'the store refused the report'
        $ev[0].detail | Should -Match '(?i)writes it again' -Because 'the person is told the next trigger writes it'
    }

    It 'a record that cannot be kept does not throw, and the report is still written' {
        Mock -ModuleName VmMigrationFactory New-VmfMigrationRecord { throw 'the records folder refused the write' }
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' }
        $r.record | Should -BeFalse
        $r.report | Should -BeTrue
        Test-Path (Join-Path $script:rp 'customer-report.html') | Should -BeTrue
        $ev = @(RaEvents $script:rp 'record' | Where-Object outcome -EQ 'warn')
        $ev.Count | Should -Be 1
        $ev[0].detail | Should -Match 'the records folder refused the write'
    }

    It 'nothing it does can throw - not even when the run history cannot be written' {
        Mock -ModuleName VmMigrationFactory New-VmfMigrationRecord { throw 'one' }
        Mock -ModuleName VmMigrationFactory New-VmfReport { throw 'two' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent { throw 'three' }
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'putBack' } } |
            Should -Not -Throw
    }

    It 'writing twice gives the same file, a day apart' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
        $first = [IO.File]::ReadAllText((Join-Path $script:rp 'customer-report.html'))
        $global:RaLater = (Get-Date).ToUniversalTime().AddDays(1).AddHours(3)
        Mock -ModuleName VmMigrationFactory Get-Date { $global:RaLater }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
        $second = [IO.File]::ReadAllText((Join-Path $script:rp 'customer-report.html'))
        Remove-Variable -Name RaLater -Scope Global -ErrorAction SilentlyContinue
        $second | Should -BeExactly $first
        # The time it shows is the newest one the record holds - a step, a
        # decision or a restore - never the time it was written.
        # ConvertFrom-Json makes an ISO time a date value (CLAUDE.md, PLANVER-2).
        $kept = Get-Content (Join-Path $script:root 'vmf-records' 'mig-auto.json') -Raw | ConvertFrom-Json
        # REPORT-AUTO-1 review 8: and the activity of the machines and the
        # run - but never the writing of the report or record, or an engine
        # start, which would make every write differ from the last.
        $acts = @(@($kept.machines | ForEach-Object { @($_.activity) }) + @($kept.runActivity) | Where-Object { $_ -and $_.step -notin @('report', 'record') -and $_.step -notlike 'engine:*' } | ForEach-Object { $_.tsUtc })
        $times = @(@($kept.machines.steps.tsUtc) + @($kept.decisions.atUtc) + $acts | Where-Object { $_ } | ForEach-Object {
            if ($_ -is [datetime]) { $_.ToUniversalTime() } else { [datetimeoffset]::Parse([string]$_, [cultureinfo]::InvariantCulture).UtcDateTime } }) | Sort-Object
        $newest = $times[-1].ToString('d MMM yyyy, HH:mm', [cultureinfo]::InvariantCulture)
        $first | Should -Match ([regex]::Escape("Last change recorded: $newest UTC"))
    }
}

Describe 'REPORT-AUTO-1: the engine calls it after a wave, a restore and a rebuild' {
    BeforeAll {
        $script:entry = Get-VmfCodeOnly -Path (Join-Path $script:repo 'docker' 'entrypoint.ps1')
        function Global:RaBranch([string]$Name) { [regex]::Match($script:entry, "(?s)\n    '$Name' \{(.*?)\n    \}").Groups[1].Value }
    }
    AfterAll { Remove-Item 'function:\RaBranch' -ErrorAction SilentlyContinue }

    It 'a wave: after the close-out, through the module' {
        $b = RaBranch 'wave'
        $b | Should -Match "Save-VmfRecordAndReport -RunPath \`$rp -Reason 'waveClosed'"
        $b.IndexOf('Save-VmfRecordAndReport') | Should -BeGreaterThan $b.IndexOf('Invoke-VmfWaveCloseOut')
        $b | Should -Not -Match 'New-VmfMigrationRecord' -Because 'one call keeps the record and writes the report, so neither is written without the other'
    }

    It 'a restore: after the restore finished' {
        $b = RaBranch 'restore'
        $b | Should -Match "Save-VmfRecordAndReport -RunPath \`$rp -Reason 'putBack'"
        $b.IndexOf('Save-VmfRecordAndReport') | Should -BeGreaterThan $b.IndexOf('Restore-VmfVm @restoreParams')
    }

    It 'REBUILD-REMOVE-RECOVER-1: there is no rebuild branch any more' {
        RaBranch 'rebuild' | Should -BeNullOrEmpty
    }

    It 'and nothing in the wave branch around it can fail the wave' {
        # Save-VmfRecordAndReport never throws (above); the call is also inside
        # a try whose catch only writes a line, so a defect in the module call
        # itself cannot turn a finished wave into a failed one.
        $b = RaBranch 'wave'
        $b | Should -Match "(?s)try \{\s*& \(Get-Module VmMigrationFactory\) \{ param\(\`$rp\) Save-VmfRecordAndReport[^\n]*\n\s*\}\s*catch \{\s*Write-Host"
    }

    It 'there is no report operation to start from a page any more' {
        RaBranch 'report' | Should -BeNullOrEmpty
        $script:entry | Should -Not -Match 'VMF_REPORT_AUDIENCE|VMF_SIGNOFF_NOTE|VMF_SIGNOFF_BY|VMF_REPORT_TITLE'
    }
}

Describe 'REPORT-AUTO-1: one report' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rauto-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:rp = RaRun $script:root
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force } }

    It 'New-VmfReport asks nobody who it is for, and takes no sign-off' {
        $params = (Get-Command New-VmfReport).Parameters.Keys
        $params | Should -Not -Contain 'Audience'
        $params | Should -Not -Contain 'SignOffBy'
        $params | Should -Not -Contain 'SignOffNote'
        (InModuleScope VmMigrationFactory { (Get-Command ConvertTo-VmfReportHtml).Parameters.Keys }) | Should -Not -Contain 'SignOffNote'
    }

    It 'writes customer-report.html and never report.html, with no appendix' {
        $path = New-VmfReport -OutPath $script:rp
        $path | Should -Match 'customer-report\.html$'
        Test-Path (Join-Path $script:rp 'report.html') | Should -BeFalse
        $html = Get-Content $path -Raw
        $html | Should -Not -Match 'Appendix|Fleet assessment|Quota records|Migration execution'
        $html | Should -Match '1</span> Results' -Because 'it is the chosen report'
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repo 'src' 'VmMigrationFactory' 'Public' 'New-VmfReport.ps1')
        $code | Should -Not -Match "'report\.html'" -Because 'nothing writes the second file'
    }

    It 'the sign-off holds the decisions the product recorded, and no row for a report nobody signs' {
        $html = Get-Content (New-VmfReport -OutPath $script:rp) -Raw
        $signoff = [regex]::Match($html, '(?s)5</span> Sign-off.*?</table>').Value
        $signoff | Should -Match '<td>Plan</td><td>approver@example.com</td>'
        $signoff | Should -Not -Match '<td>Report'
    }

    It 'the stored report carries no theme mark: no person wrote it, so the reader''s system decides' {
        $html = Get-Content (New-VmfReport -OutPath $script:rp) -Raw
        $html | Should -Match '<html lang="en">'
        $html | Should -Not -Match '<html[^>]*data-theme'
    }
}

Describe 'REPORT-AUTO-1: every fact the appendix held is in the record' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rauto-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:rp = RaRun $script:root
        $script:rec = Export-VmfMigrationRecord -RunPath $script:rp -GeneratedBy 'admin@example.com'
        $script:of = { param($n) @($script:rec.machines | Where-Object name -EQ $n)[0] }
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force } }

    It 'is version 4 and what the contract says' {
        $script:rec.schemaVersion | Should -Be 5
        Get-Content (Join-Path $script:root 'vmf-records' 'mig-auto.json') -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
    }

    It 'the fleet assessment: machines scanned and the count by classification' {
        $script:rec.assessment.machines | Should -Be 3
        $script:rec.assessment.byClassification.ReadyAfterPrep | Should -Be 2
        $script:rec.assessment.byClassification.Blocked | Should -Be 1
        $script:rec.assessment.byClassification.PSObject.Properties.Name | Should -Not -Contain 'ReadyNow'
        $script:rec.assessment.notInMigration | Should -Be 0 -Because 'every machine the scan found is in this plan'
    }

    # MACHINE-PICK-1 (merged while this was built): the old appendix showed a
    # scanned machine the plan holds no entry for as "Not in this migration".
    # The appendix is gone; the count is in the record, by the same rule: no
    # plan entry while the plan has entries, not Excluded, not platform-managed.
    It 'the machines the scan found that are not in this migration are counted, by the rule the appendix used' {
        $a = Get-Content (Join-Path $script:rp 'assessment.json') -Raw | ConvertFrom-Json
        $sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
        $extra = @(
            [pscustomobject]@{ vmId = "${sub}spare-1"; name = 'spare-1'; classification = 'ReadyAfterPrep'; platformManaged = $false; blockers = @(); prepNeeded = @() },
            [pscustomobject]@{ vmId = "${sub}spare-2"; name = 'spare-2'; classification = 'Blocked'; blockers = @('gen1-requires-redeploy'); prepNeeded = @() },
            [pscustomobject]@{ vmId = "${sub}aks-node"; name = 'aks-node'; classification = 'Excluded'; blockers = @(); prepNeeded = @() },
            [pscustomobject]@{ vmId = "${sub}pool-1"; name = 'pool-1'; classification = 'ReadyAfterPrep'; platformManaged = $true; blockers = @(); prepNeeded = @() })
        $a.vms = @($a.vms) + $extra
        $a | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:rp 'assessment.json')
        $r = Export-VmfMigrationRecord -RunPath $script:rp -GeneratedBy 'admin@example.com'
        $r.assessment.notInMigration | Should -Be 2 -Because 'spare-1 and spare-2; never an Excluded or a platform-managed machine'
        Get-Content (Join-Path $script:root 'vmf-records' 'mig-auto.json') -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
    }

    It 'before a plan holds any machine, no machine is counted as not in this migration' {
        $p = Get-Content (Join-Path $script:rp 'plan.json') -Raw | ConvertFrom-Json
        $p.entries = @()
        $p | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:rp 'plan.json')
        (Export-VmfMigrationRecord -RunPath $script:rp -GeneratedBy 'admin@example.com').assessment.notInMigration | Should -Be 0
    }

    It 'each machine''s classification, generation, disk architecture, blockers and preparation' {
        $web = & $script:of 'web'
        $web.assessment.classification | Should -Be 'ReadyAfterPrep'
        $web.assessment.generation | Should -Be 'V2'
        $web.assessment.diskArchitecture | Should -Be 'scsi-temp'
        @($web.assessment.issues) | Should -Be @('stornvme', 'pagefile')
        # REVIEW-1: judged for the series ITS entry moves to. The scan blocked
        # db for every series at once; on v5, Generation 1 and the NVMe
        # preparation do not apply, so it is ready after preparation with
        # nothing listed.
        $db = & $script:of 'db'
        $db.assessment.classification | Should -Be 'ReadyAfterPrep'
        $db.assessment.generation | Should -Be 'V1'
        $db.assessment.diskArchitecture | Should -Be 'diskless'
        @($db.assessment.issues).Count | Should -Be 0
    }

    It 'a machine the plan does not move is Blocked, with the plan''s reason - as the appendix judged it' {
        $app = & $script:of 'app'
        $app.assessment.classification | Should -Be 'Blocked' -Because 'V5-ADE-1: the scan said ready, the plan does not move it'
        @($app.assessment.issues) | Should -Be @('No target was chosen for this machine, so it is not moved.')
    }

    It 'the plan: size alternates and notes, per machine' {
        @((& $script:of 'web').sizeAlternates) | Should -Be @('Standard_D4ads_v6')
        @((& $script:of 'db').sizeAlternates) | Should -Be @('Standard_E2as_v5', 'Standard_E2ds_v5')
        @((& $script:of 'db').planNotes) | Should -Be @('check the initramfs')
        @((& $script:of 'app').sizeAlternates).Count | Should -Be 0 -Because 'BSV2-NOTES-1: an empty alternate in an older plan is no size, and the report names none'
    }

    It 'the execution: the checkpoint each machine reached' {
        (& $script:of 'web').pathCheckpoint | Should -Be 'B:recreated'
        (& $script:of 'db').pathCheckpoint | Should -BeNullOrEmpty -Because 'db has not started'
    }

    It 'the quota records: wave, region, zone, size, family, vCPUs, quota used and limit, state and notes' {
        @($script:rec.quotaRecords).Count | Should -Be 1
        $q = @($script:rec.quotaRecords)[0]
        $q.wave | Should -Be 'w1'
        $q.region | Should -Be 'centralus'
        $q.zone | Should -Be '2'
        $q.size | Should -Be 'Standard_D4ds_v6'
        $q.family | Should -Be 'standardDDSv6Family'
        $q.vcpus | Should -Be 4
        $q.quotaUsed | Should -Be 12
        $q.quotaLimit | Should -Be 40
        $q.state | Should -Be 'QUOTA_VERIFIED'
        @($q.notes) | Should -Be @('family read from the usage list')
    }

    It 'a run with no assessment and no quota records says so as empty, not as an error' {
        Remove-Item (Join-Path $script:rp 'assessment.json'), (Join-Path $script:rp 'capacity') -Recurse -Force
        $r = Export-VmfMigrationRecord -RunPath $script:rp -GeneratedBy 'admin@example.com'
        $r.assessment | Should -BeNullOrEmpty
        @($r.quotaRecords).Count | Should -Be 0
        (& { @($r.machines | Where-Object name -EQ 'web')[0] }).assessment | Should -BeNullOrEmpty
        Get-Content (Join-Path $script:root 'vmf-records' 'mig-auto.json') -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
    }
}

Describe 'REPORT-AUTO-1: nothing from a page starts a report' {

    It 'the service has no report operation, and none of the dialog''s fields' {
        $cmd = Get-Command Invoke-VmfFacadeStartEngine
        $ops = @($cmd.Parameters['Operation'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
            ForEach-Object { $_.ValidValues })
        $ops.Count | Should -BeGreaterThan 5 -Because 'otherwise this reads nothing'
        $ops | Should -Not -Contain 'report'
        foreach ($p in 'ReportAudience', 'ReportTitle', 'SignOffNote') { $cmd.Parameters.Keys | Should -Not -Contain $p }
    }

    It 'the start route reads none of them from the body' {
        $route = Get-VmfCodeOnly -Path (Join-Path $script:repo 'src' 'facade' 'app' 'PostStartEngine' 'run.ps1')
        $route | Should -Not -Match 'reportAudience|reportTitle|signOffNote'
        $route | Should -Match 'Invoke-VmfFacadeStartEngine @params' -Because 'the route under test is the real one'
    }

    It 'New-VmfReport is exempt from the reachability rule as engine library, because a person never runs it' {
        $reach = Get-Content (Join-Path $script:repo 'tests' 'unit' 'Reachability.Tests.ps1') -Raw
        $reach | Should -Match "'New-VmfReport'\s*=\s*'library - "
    }
}
# ---------------------------------------------------------------------------
# The independent review of REPORT-AUTO-1, 2026-10-02. Each Describe below is
# one of its findings, tested before the fix.
# ---------------------------------------------------------------------------

Describe 'REPORT-AUTO-1 review 1: a container that finishes only its share of a wave writes nothing' {
    # SCALE-2: a wave split over containers. A container whose workers are
    # done while another container still works returns with FinishedShare.
    # It wrote the record and the report anyway, so a half-finished report
    # could land after the last container's whole one - and its close-out
    # warned that reservations were "STILL HELD" while the wave was running.
    BeforeAll {
        $script:entryCode = Get-VmfCodeOnly -Path (Join-Path $script:repo 'docker' 'entrypoint.ps1')
        $script:waveBranch = [regex]::Match($script:entryCode, "(?s)\n    'wave' \{(.*?)\n    \}").Groups[1].Value
    }

    It 'the share-only test reads FinishedShare, and a plain result is a closed wave' {
        InModuleScope VmMigrationFactory {
            Test-VmfWaveShareOnly -Result ([pscustomobject]@{ Wave = 'w1'; FinishedShare = $true }) | Should -BeTrue
            Test-VmfWaveShareOnly -Result ([pscustomobject]@{ Wave = 'w1'; StateCounts = @{} }) | Should -BeFalse
            Test-VmfWaveShareOnly -Result ([pscustomobject]@{ Wave = 'w1'; FinishedShare = $false }) | Should -BeFalse
            Test-VmfWaveShareOnly -Result $null | Should -BeFalse
        }
    }

    It 'the wave branch closes out and writes the record and report only when the wave closed' {
        $script:waveBranch | Should -Match "Test-VmfWaveShareOnly -Result"
        $guarded = [regex]::Match($script:waveBranch, '(?s)if \(\$shareOnly\) \{(.*?)\n        \}\s*else \{(.*)$')
        $guarded.Success | Should -BeTrue -Because 'the close-out and the write sit in the else of the share-only test'
        $guarded.Groups[1].Value | Should -Not -Match 'Invoke-VmfWaveCloseOut|Save-VmfRecordAndReport'
        $guarded.Groups[2].Value | Should -Match 'Invoke-VmfWaveCloseOut'
        $guarded.Groups[2].Value | Should -Match 'Save-VmfRecordAndReport'
    }

    It 'the close-out itself does nothing and says nothing for a share-only result' {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rauto-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $rp = RaRun $root
            $claim = Get-Content (Join-Path $rp 'capacity' 'w1-centralus.json') -Raw | ConvertFrom-Json
            $claim.state = 'RESERVED'
            $claim | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $rp 'capacity' 'w1-centralus.json')
            Mock -ModuleName VmMigrationFactory Remove-VmfCapacityReservations { throw 'must not be called' }
            $r = Invoke-VmfWaveCloseOut -RunPath $rp -Wave 'w1' -Result ([pscustomobject]@{ Wave = 'w1'; StateCounts = [pscustomobject]@{ PRECHECK = 1 }; Halted = $false; FinishedShare = $true })
            $r.Action | Should -Be 'none'
            @(RaEvents $rp 'odcr').Count | Should -Be 0 -Because 'the wave is still running in another container; held capacity is not news yet'
        }
        finally { if (Test-Path $root) { Remove-Item $root -Recurse -Force } }
    }
}

Describe 'REPORT-AUTO-1 review 3: a stopped migration and the daily check write the report again' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rauto-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:rp = RaRun $script:root
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force } }

    It 'Stop this migration writes the record and the report when it finishes' {
        Stop-VmfRun -RunPath $script:rp -Reason 'cannot finish' -StoppedBy 'operator@example.com' -Confirm:$false | Out-Null
        ((Get-Content (Join-Path $script:root 'vmf-records' 'mig-auto.json') -Raw) | ConvertFrom-Json).reason | Should -Be 'stopped'
        Test-Path (Join-Path $script:rp 'customer-report.html') | Should -BeTrue
        Get-Content (Join-Path $script:rp 'customer-report.html') -Raw | Should -Match 'Left out' -Because 'the report shows the machines the stop closed out'
    }

    It 'the warning says the daily check writes it again - a trigger that always comes' {
        Mock -ModuleName VmMigrationFactory New-VmfReport { throw 'refused' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
        @(RaEvents $script:rp 'report')[-1].detail | Should -Match '(?i)the daily check'
    }

    It 'the daily check writes a report whose last write failed' {
        Mock -ModuleName VmMigrationFactory New-VmfReport { throw 'refused' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
        Remove-Item (Join-Path $script:rp 'customer-report.html') -ErrorAction SilentlyContinue
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Update-VmfStaleReport -RunPath $rp }
        $r | Should -Be 'failed' -Because 'the mock still refuses, and the check says so rather than claiming it wrote it'
    }

    It 'the daily check writes it once the store takes it, and the record says why' {
        # One mock with a switch: a second Mock of the same command in one It
        # does not replace the first.
        $global:RaRefuse = $true
        try {
            Mock -ModuleName VmMigrationFactory New-VmfReport { if ($global:RaRefuse) { throw 'refused' }; 'x' }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
            $global:RaRefuse = $false
            $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Update-VmfStaleReport -RunPath $rp }
        }
        finally { Remove-Variable -Name RaRefuse -Scope Global -ErrorAction SilentlyContinue }
        $r | Should -Be 'written'
        ((Get-Content (Join-Path $script:root 'vmf-records' 'mig-auto.json') -Raw) | ConvertFrom-Json).reason | Should -Be 'dailyCheck'
    }

    It 'a report newer than every change is left alone' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
        Mock -ModuleName VmMigrationFactory Save-VmfRecordAndReport { throw 'must not be called' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Update-VmfStaleReport -RunPath $rp } | Should -Be 'current'
    }

    It 'a report older than the last recorded change is written again' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
        # A change after the report: a capacity release the engine logged, an
        # hour from now so it is later than the report whatever the clock does.
        $later = (Get-Date).ToUniversalTime().AddHours(1).ToString('o')
        Add-Content -Path (Join-Path $script:rp 'logs' 'events.jsonl') -Value ('{"tsUtc":"' + $later + '","step":"odcr","outcome":"ok","detail":"released"}')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Update-VmfStaleReport -RunPath $rp } | Should -Be 'written'
    }

    It 'a migration that has never had a report, and has changes, gets one' {
        Test-Path (Join-Path $script:rp 'customer-report.html') | Should -BeFalse
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Update-VmfStaleReport -RunPath $rp } | Should -Be 'written'
        Test-Path (Join-Path $script:rp 'customer-report.html') | Should -BeTrue
    }

    # Two cases the cases above hid behind another rule (mutation-tested):
    # a report that exists and failed only on its LAST write, and a report
    # whose file is gone although it was written after every change.
    It 'a report written once, whose newest write failed, is written again' {
        $global:RaRefuse = $false
        try {
            Mock -ModuleName VmMigrationFactory New-VmfReport -ParameterFilter { $global:RaRefuse } { throw 'refused' }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
            Test-Path (Join-Path $script:rp 'customer-report.html') | Should -BeTrue
            $global:RaRefuse = $true
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'putBack' } | Out-Null
            $global:RaRefuse = $false
            $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Update-VmfStaleReport -RunPath $rp }
        }
        finally { Remove-Variable -Name RaRefuse -Scope Global -ErrorAction SilentlyContinue }
        $r | Should -Be 'written' -Because 'nothing changed after the failed write, and it is still the one to repair'
    }

    It 'a report whose file is gone is written again, even with no change since' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
        [IO.File]::Delete((Join-Path $script:rp 'customer-report.html'))
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Update-VmfStaleReport -RunPath $rp } | Should -Be 'written'
        Test-Path (Join-Path $script:rp 'customer-report.html') | Should -BeTrue
    }

    # REPORT-RECORD-LINE-1: the record half of the same check. A record that
    # failed while the report after it was written left only a warning OLDER
    # than the report's line, so the check saw a current report and did
    # nothing - there was no "record written" line to compare with.
    It 'keeping the record leaves a line in the run history, in the shape the report write leaves, before the report''s' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
        $kept = @(RaEvents $script:rp 'record' | Where-Object outcome -EQ 'ok')
        $kept.Count | Should -Be 1
        $kept[0].detail | Should -Be (Join-Path $script:root 'vmf-records' 'mig-auto.json') -Because 'the report line names where the report went; this names where the record went'
        $kept[0].PSObject.Properties['vmId'] | Should -BeNullOrEmpty -Because 'it is a line about the whole migration'
        $all = @(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        $recordAt = [array]::FindIndex($all, [Predicate[object]] { param($e) $e.step -eq 'record' -and $e.outcome -eq 'ok' })
        $reportAt = [array]::FindIndex($all, [Predicate[object]] { param($e) $e.step -eq 'report' -and $e.outcome -eq 'ok' })
        $recordAt | Should -BeLessThan $reportAt
    }

    It 'a download keeps the record too, and leaves the same line' {
        Export-VmfMigrationRecord -RunPath $script:rp -GeneratedBy 'admin@example.com' | Out-Null
        @(RaEvents $script:rp 'record' | Where-Object outcome -EQ 'ok').Count | Should -Be 1
    }

    It 'a line that cannot be written does not turn a kept record into a failure' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'record' -and $Outcome -eq 'ok' } { throw 'the run history refused the line' }
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' }
        $r.record | Should -BeTrue
        @(RaEvents $script:rp 'record' | Where-Object outcome -EQ 'warn').Count | Should -Be 0 -Because 'the record was kept; saying it was not would be false'
    }

    It 'the daily check writes both again when the record failed and the report after it was written' {
        $global:RaRefuse = $true
        try {
            Mock -ModuleName VmMigrationFactory New-VmfMigrationRecord -ParameterFilter { $global:RaRefuse } { throw 'the records folder refused the write' }
            $first = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' }
            $first.record | Should -BeFalse
            $first.report | Should -BeTrue
            $global:RaRefuse = $false
            $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Update-VmfStaleReport -RunPath $rp }
        }
        finally { Remove-Variable -Name RaRefuse -Scope Global -ErrorAction SilentlyContinue }
        $r | Should -Be 'written'
        ((Get-Content (Join-Path $script:root 'vmf-records' 'mig-auto.json') -Raw) | ConvertFrom-Json).reason | Should -Be 'dailyCheck'
    }

    It 'a record written once, whose newest write failed, is written again although the report is current' {
        $global:RaRefuse = $false
        try {
            Mock -ModuleName VmMigrationFactory New-VmfMigrationRecord -ParameterFilter { $global:RaRefuse } { throw 'refused' }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
            $global:RaRefuse = $true
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'putBack' } | Out-Null
            $global:RaRefuse = $false
            $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Update-VmfStaleReport -RunPath $rp }
        }
        finally { Remove-Variable -Name RaRefuse -Scope Global -ErrorAction SilentlyContinue }
        $r | Should -Be 'written' -Because 'the kept record is from before the restore'
        ((Get-Content (Join-Path $script:root 'vmf-records' 'mig-auto.json') -Raw) | ConvertFrom-Json).reason | Should -Be 'dailyCheck'
    }

    It 'the check says failed while the record cannot be kept, although the report was written' {
        Mock -ModuleName VmMigrationFactory New-VmfMigrationRecord { throw 'refused' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Update-VmfStaleReport -RunPath $rp } | Should -Be 'failed'
    }

    It 'a migration with no record line - one from before the line existed - has its record written' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
        $log = Join-Path $script:rp 'logs' 'events.jsonl'
        $older = @(Get-Content $log | Where-Object { ($_ | ConvertFrom-Json).step -ne 'record' })
        Set-Content -Path $log -Value $older
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Update-VmfStaleReport -RunPath $rp } | Should -Be 'written'
        @(RaEvents $script:rp 'record' | Where-Object outcome -EQ 'ok').Count | Should -Be 1
    }

    It 'a record whose file is gone is written again, even with no change since' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
        [IO.File]::Delete((Join-Path $script:root 'vmf-records' 'mig-auto.json'))
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Update-VmfStaleReport -RunPath $rp } | Should -Be 'written'
        Test-Path (Join-Path $script:root 'vmf-records' 'mig-auto.json') | Should -BeTrue
    }

    It 'a record older than the last change is written again, when only the report was written after it' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
        $later = (Get-Date).ToUniversalTime().AddHours(1).ToString('o')
        Add-Content -Path (Join-Path $script:rp 'logs' 'events.jsonl') -Value ('{"tsUtc":"' + $later + '","step":"odcr","outcome":"ok","detail":"released"}')
        # The report alone, written after that change - as a drill writes it.
        $evenLater = (Get-Date).ToUniversalTime().AddHours(2).ToString('o')
        Add-Content -Path (Join-Path $script:rp 'logs' 'events.jsonl') -Value ('{"tsUtc":"' + $evenLater + '","step":"report","outcome":"ok","detail":"customer-report.html"}')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Update-VmfStaleReport -RunPath $rp } | Should -Be 'written'
    }

    It 'inside a project, the check looks for the record where it was kept' {
        # Review finding 3: the record of a run in a project is kept beside the
        # projects, under the project and run name.
        $proot = Join-Path $script:root 'stores'
        $rp = Join-Path $proot 'estate' 'mig-proj'
        $sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; sub = $sub } {
            param($rp, $sub)
            Initialize-VmfRun -RunPath $rp -RunId 'mig-proj' -Kind 'migration' -Project 'estate' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'mig-proj' -VmId "${sub}web" -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId "${sub}web" -NewState 'MIGRATED' -Outcome ok | Out-Null
            Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' | Out-Null
        }
        $kept = Join-Path $proot 'vmf-records' 'estate--mig-proj.json'
        Test-Path $kept | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Update-VmfStaleReport -RunPath $rp } | Should -Be 'current'
        [IO.File]::Delete($kept)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Update-VmfStaleReport -RunPath $rp } | Should -Be 'written'
        Test-Path $kept | Should -BeTrue
    }

    It 'a record and a report newer than every change are left alone' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' } | Out-Null
        Mock -ModuleName VmMigrationFactory Save-VmfRecordAndReport { throw 'must not be called' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Update-VmfStaleReport -RunPath $rp } | Should -Be 'current'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Update-VmfStaleReport -RunPath $rp } | Should -Be 'current' -Because 'the check itself leaves nothing that makes the next one write'
    }

    It 'the daily timer asks it of every migration, in its own error handling' {
        $runner = Get-VmfCodeOnly -Path (Join-Path $script:repo 'src' 'facade' 'app' 'RetentionRunner' 'run.ps1')
        $loop = [regex]::Match($runner, '(?s)foreach \(\$runId in \$runIds\) \{(.*)').Groups[1].Value
        $at = $loop.IndexOf('Update-VmfStaleReport')
        $at | Should -BeGreaterThan 0
        # RETAIN-KIND-1 review: the gate is now a verdict from the one rule; the
        # text it looks for must be found, or the order check means nothing.
        $gate = $loop.IndexOf("if (`$verdict -ne 'migration') { continue }")
        $gate | Should -BeGreaterThan 0
        $at | Should -BeGreaterThan $gate -Because 'only a migration has a report'
        $loop | Should -Match '(?s)try \{\s*\$state = [^\n]*Update-VmfStaleReport[^\n]*\n\s*if [^\n]*\n\s*\}\s*catch \{' -Because 'one run that cannot be written does not stop the pass'
    }
}

Describe 'REPORT-AUTO-1 review 5: a malformed assessment or quota record cannot block the record' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rauto-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:rp = RaRun $script:root
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force } }

    It 'a broken assessment reads as none, with a warning' {
        Set-Content (Join-Path $script:rp 'assessment.json') '{ not json'
        $r = Export-VmfMigrationRecord -RunPath $script:rp -GeneratedBy 'admin@example.com'
        $r.assessment | Should -BeNullOrEmpty
        @($r.machines).Count | Should -Be 3 -Because 'the rest of the record is there'
        (@(RaEvents $script:rp 'record' | Where-Object outcome -EQ 'warn').detail -join ' ') | Should -Match 'assessment'
    }

    It 'a broken quota record is left out, with a warning, and the others stay' {
        Set-Content (Join-Path $script:rp 'capacity' 'broken.json') '{ not json'
        $r = Export-VmfMigrationRecord -RunPath $script:rp -GeneratedBy 'admin@example.com'
        @($r.quotaRecords).Count | Should -Be 1
        (@(RaEvents $script:rp 'record' | Where-Object outcome -EQ 'warn').detail -join ' ') | Should -Match 'quota record'
    }

    # Only the assessment here: the delete reads the quota records itself, to
    # refuse while a reservation is held, and that read is the delete's own
    # (another work item changes the delete path).
    It 'and a delete still keeps the record first' {
        Set-Content (Join-Path $script:rp 'assessment.json') '{ not json'
        { Remove-VmfRun -RunPath $script:rp -Reason 'done' -RemovedBy 'operator@example.com' -KeepSafetyCopies -Confirm:$false } | Should -Not -Throw
        Test-Path (Join-Path $script:root 'vmf-records' 'mig-auto.json') | Should -BeTrue
    }
}

Describe 'REPORT-AUTO-1 review 6: the order of machines does not depend on the process' {
    It 'machines not in the plan come in vmId order, not hash order' {
        $names = 1..24 | ForEach-Object { 'm{0:D2}' -f $_ }
        $shuffled = $names | Sort-Object { [guid]::NewGuid() }
        $rec = InModuleScope VmMigrationFactory -Parameters @{ n = @($shuffled) } { param($n)
            $docs = foreach ($x in $n) { [pscustomobject]@{ vmId = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$x"; state = 'MIGRATED'; history = @() } }
            ConvertTo-VmfMigrationRecord -Manifest @{ runId = 'r' } -Plan $null -StateDocs @($docs) -GeneratedBy 'x' -Reason 'downloaded'
        }
        @($rec.machines | ForEach-Object { $_.name }) -join ',' | Should -Be ($names -join ',')
    }

    It 'the Exceptions rows come in name order' {
        $html = InModuleScope VmMigrationFactory {
            $m = { param($n) [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/x/$n"; name = $n; wave = 'w'; path = 'A'; state = 'FAILED_ROLLED_BACK'; outcome = 'rolledBack'
                before = @{ size = 'a' }; target = @{ size = 'b' }; now = @{ size = 'a'; basis = 'x' }; steps = @(); guestScripts = @(); activity = @() } }
            ConvertTo-VmfReportHtml -Record ([ordered]@{ runId = 'r'; decisions = @(); machines = @((& $m 'zeta'), (& $m 'alpha'), (& $m 'mid')) })
        }
        $ex = [regex]::Match($html, '(?s)4</span> Exceptions.*?</section>').Value
        $ex.IndexOf('>alpha<') | Should -BeLessThan $ex.IndexOf('>mid<')
        $ex.IndexOf('>mid<') | Should -BeLessThan $ex.IndexOf('>zeta<')
    }
}

Describe 'REPORT-AUTO-1 review 8: the footer time includes every change the record holds' {
    BeforeAll {
        $script:lc = { param($rec) InModuleScope VmMigrationFactory -Parameters @{ r = $rec } { param($r) Get-VmfRecordLastChange -Record $r } }
        $script:base = { [ordered]@{ decisions = @([ordered]@{ atUtc = '2026-10-01T01:00:00Z' }); runActivity = @()
            machines = @([ordered]@{ steps = @([ordered]@{ tsUtc = '2026-10-01T02:00:00Z' }); activity = @() }) } }
    }

    It 'a capacity release the engine logged moves it' {
        $r = & $script:base; $r.runActivity = @([ordered]@{ tsUtc = '2026-10-01T05:00:00Z'; step = 'odcr'; outcome = 'ok' })
        (& $script:lc $r).ToString('HH:mm') | Should -Be '05:00'
    }

    It 'a machine''s own activity moves it' {
        $r = & $script:base; $r.machines[0].activity = @([ordered]@{ tsUtc = '2026-10-01T06:00:00Z'; step = 'restore:start'; outcome = 'ok' })
        (& $script:lc $r).ToString('HH:mm') | Should -Be '06:00'
    }

    It 'a deletion of safety copies moves it' {
        $r = & $script:base; $r.machines[0].retention = [ordered]@{ deletedUtc = '2026-10-01T08:00:00Z' }
        (& $script:lc $r).ToString('HH:mm') | Should -Be '08:00'
    }

    It 'writing the report, the record, or starting the engine is not a change' {
        $r = & $script:base
        $r.runActivity = @([ordered]@{ tsUtc = '2026-10-01T09:00:00Z'; step = 'report'; outcome = 'ok' },
                           [ordered]@{ tsUtc = '2026-10-01T09:30:00Z'; step = 'record'; outcome = 'warn' },
                           [ordered]@{ tsUtc = '2026-10-01T10:00:00Z'; step = 'engine:wave'; outcome = 'info' })
        (& $script:lc $r).ToString('HH:mm') | Should -Be '02:00' -Because 'otherwise every write would change the next one, and two writes would differ'
    }
}

Describe 'RECORD-UNMOVED-1: a machine the plan does not move is Not moved, as the run page says' {
    # The run page (MANUAL-WHY-1) shows a machine whose plan entry is MANUAL or
    # EXCLUDED, and which has no state past PLANNED, as "Not moved" - never as
    # waiting to start. The record called it "Not started" in its summary and
    # its machine table, and so did the report drawn from it. In the fixture,
    # app is MANUAL with no state, and db is a path A machine not started yet.
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-unmoved-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $script:rp = RaRun $script:root
        $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
        $script:of = { param($r, $n) @($r.machines | Where-Object name -EQ $n)[0] }
        $script:setPath = { param($n, $path)
            $plan = Get-Content (Join-Path $script:rp 'plan.json') -Raw | ConvertFrom-Json
            foreach ($e in @($plan.entries)) { if ($e.vmId -eq "$script:sub$n") { $e.path = $path } }
            $plan | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:rp 'plan.json') }
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force } }

    It 'the record: the MANUAL machine is notMoved, the path A machine not started yet is notStarted' {
        $r = Export-VmfMigrationRecord -RunPath $script:rp -GeneratedBy 'admin@example.com'
        (& $script:of $r 'app').outcome | Should -Be 'notMoved'
        (& $script:of $r 'db').outcome | Should -Be 'notStarted' -Because 'the plan moves db; its wave has not run'
        (& $script:of $r 'web').outcome | Should -Be 'migrated'
        $r.summary.notMoved | Should -Be 1
        $r.summary.notStarted | Should -Be 1 -Because 'only db; app is counted apart'
        $r.summary.migrated | Should -Be 1
        Get-Content (Join-Path $script:root 'vmf-records' 'mig-auto.json') -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
    }

    It 'an EXCLUDED entry is Not moved too - the run page names both' {
        & $script:setPath 'app' 'EXCLUDED'
        $r = Export-VmfMigrationRecord -RunPath $script:rp -GeneratedBy 'admin@example.com'
        (& $script:of $r 'app').outcome | Should -Be 'notMoved'
    }

    It 'a machine the plan does not move, with a state document still at PLANNED, is Not moved' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = "$($script:sub)app" } { param($rp, $id)
            New-VmfStateDoc -RunPath $rp -RunId 'mig-auto' -VmId $id -Wave 'unscheduled' | Out-Null }
        $r = Export-VmfMigrationRecord -RunPath $script:rp -GeneratedBy 'admin@example.com'
        (& $script:of $r 'app').outcome | Should -Be 'notMoved'
    }

    It 'a state past PLANNED keeps its own outcome: the run page shows Not moved only for a machine that has not started' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = "$($script:sub)app" } { param($rp, $id)
            New-VmfStateDoc -RunPath $rp -RunId 'mig-auto' -VmId $id -Wave 'unscheduled' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'PRECHECK' -Outcome ok | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok | Out-Null }
        $r = Export-VmfMigrationRecord -RunPath $script:rp -GeneratedBy 'admin@example.com'
        (& $script:of $r 'app').outcome | Should -Be 'migrated'
        $r.summary.notMoved | Should -Be 0
    }

    It 'the report: the results and the machine table say Not moved for app, and Not started only for db' {
        $html = Get-Content (New-VmfReport -OutPath $script:rp) -Raw
        $results = [regex]::Match($html, '(?s)1</span> Results.*?</section>').Value
        $results | Should -Match '<b>1</b><span>Not moved</span>'
        $results | Should -Match '<b>1</b><span>Not started</span>' -Because 'db is in the plan and has not started'
        $app = [regex]::Match($html, '(?s)<div class="nm">app</div>.*?</tr>').Value
        $app | Should -Match '<span class="pill quiet">Not moved</span>'
        $app | Should -Not -Match 'Not started'
        $db = [regex]::Match($html, '(?s)<div class="nm">db</div>.*?</tr>').Value
        $db | Should -Match '<span class="pill quiet">Not started</span>'
    }
}