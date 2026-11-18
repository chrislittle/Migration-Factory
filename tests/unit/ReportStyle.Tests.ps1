#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# VERIFY-FP-1 part 3b: the report style chosen on 2026-09-28 (Style A).
#
# The earlier report was prose, not a report, and its subtitle assumed one
# kind of move when a run can hold dozens of configurations. So the report
# is facts in tables, built from the migration record:
# results, the moves grouped by size and method, every machine with its
# evidence, the exceptions, and the sign-off.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $sub = '00000000-0000-0000-0000-000000000000'
    $mk = { param($name, $wave, $from, $to, $path, $outcome, $start, $end, $extra)
        $m = [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion);
            vmId = "/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$name"; name = $name; wave = $wave; path = $path
            state = 'MIGRATED'; outcome = $outcome
            before = [ordered]@{ size = $from; controller = 'SCSI'; os = 'Linux'; osVersion = '22_04-lts-gen2' }
            target = [ordered]@{ size = $to; controller = 'NVMe' }
            now = [ordered]@{ size = $(if ($outcome -eq 'migrated') { $to } else { $from }); controller = 'NVMe'; basis = 'read from Azure after the move' }
            steps = @([ordered]@{ tsUtc = '2026-10-14T19:00:00Z'; state = 'PLANNED'; outcome = 'ok' },
                      [ordered]@{ tsUtc = $start; state = 'PRECHECK'; outcome = 'ok' },
                      [ordered]@{ tsUtc = $end; state = $(if ($outcome -eq 'rolledBack') { 'FAILED_ROLLED_BACK' } else { 'MIGRATED' }); outcome = 'ok'; detail = 'STARTING failed; rolled back: agent timeout' })
            guestScripts = @(); activity = @()
        }
        foreach ($k in @($extra.Keys)) { $m[$k] = $extra[$k] }
        $m }
    $evidence = [ordered]@{ takenUtc = '2026-10-14T20:31:00Z'; rows = @(
        [ordered]@{ key = 'azure.size'; group = 'azure'; label = 'Size'; before = 'Standard_D2s_v4'; after = 'Standard_D2s_v6'; result = 'planned' }
        [ordered]@{ key = 'azure.osDisk'; group = 'azure'; label = 'OS disk'; before = 'a_OsDisk_1'; after = 'a_OsDisk_1'; result = 'same' }
        [ordered]@{ key = 'imds.answered'; group = 'imds'; label = 'Answered'; before = 'Yes'; after = 'Yes'; result = 'same' }
        [ordered]@{ key = 'guest.bootBus'; group = 'guest'; label = 'Boot disk bus'; before = $null; after = 'NVMe'; result = 'notRead' }) }
    $script:record = [ordered]@{
        schemaVersion = 2; runId = 'finance-2026-10'; project = 'Contoso finance'
        decisions = @([ordered]@{ what = 'signed off the plan'; wave = $null; by = 'approver@example.com'; atUtc = '2026-10-13T16:02:00Z' },
                      [ordered]@{ what = 'approved the wave'; wave = 'billing'; by = 'approver@example.com'; atUtc = '2026-10-14T21:05:00Z' })
        machines = @(
            (& $mk 'can-lin-a' 'storefront' 'Standard_D2s_v4' 'Standard_D2s_v6' 'A' 'migrated' '2026-10-14T20:00:00Z' '2026-10-14T20:31:00Z' @{ evidence = $evidence })
            (& $mk 'can-lin-b' 'storefront' 'Standard_D2s_v4' 'Standard_D2s_v6' 'A' 'migrated' '2026-10-14T20:04:00Z' '2026-10-14T20:37:00Z' @{})
            (& $mk 'prd-win-a' 'billing' 'Standard_D2ds_v4' 'Standard_D2ds_v6' 'A' 'putBack' '2026-10-14T21:44:00Z' '2026-10-14T22:20:00Z' @{
                putBack = [ordered]@{ restoredUtc = '2026-10-14T22:41:00Z'; restoredBy = 'operator@example.com'; note = 'Application owner request'; sizeAfter = 'Standard_D2ds_v4' } })
            (& $mk 'prd-<b>x</b>' 'billing' 'Standard_D2ds_v4' 'Standard_D2ds_v6' 'A' 'rolledBack' '2026-10-14T22:00:00Z' '2026-10-14T23:10:00Z' @{})
        )
    }
    $script:html = InModuleScope VmMigrationFactory -Parameters @{ r = $script:record } { param($r) ConvertTo-VmfReportHtml -Record $r }
}

Describe 'VERIFY-FP-1 part 3b: the cover' {
    It 'carries the mark, the name, the migration and the window it ran in - nothing that assumes one kind of move' {
        $script:html | Should -Match '<svg viewBox="0 0 32 32"'
        $script:html | Should -Match 'Migration Factory</div><h1>Migration report</h1>'
        $script:html | Should -Match 'finance-2026-10'
        $script:html | Should -Match 'Contoso finance'
        $script:html | Should -Match '14 Oct 2026, 20:00&ndash;23:10 UTC' -Because 'the first step of the first machine to the last step of the last'
        $script:html | Should -Match '4 machines &middot; 2 waves &middot; 1 subscription<'
        $script:html | Should -Not -Match 'SCSI to NVMe on the v6'
    }
}

Describe 'VERIFY-FP-1 part 3b: the sections are tables of facts' {
    It 'results count each outcome that happened, and the average time of a migrated machine' {
        $s = [regex]::Match($script:html, '(?s)1</span> Results.*?</section>').Value
        $s | Should -Match '<b>2</b><span>Migrated</span>'
        $s | Should -Match '<b>1</b><span>Restored</span>'
        $s | Should -Match '<b>1</b><span>Rolled back</span>'
        $s | Should -Match '<b>32 min</b>' -Because '31 and 33 minutes'
    }

    It 'moves: one row for each size, target and method, with how many and how many migrated' {
        $s = [regex]::Match($script:html, '(?s)2</span> Moves.*?</section>').Value
        $s | Should -Match 'Standard_D2s_v4</td><td class="mono">Standard_D2s_v6</td><td>SCSI <span class="arr">&rarr;</span> NVMe</td><td>In-place upgrade</td><td class="n">2</td><td class="n">2</td>'
        $s | Should -Match 'Standard_D2ds_v4</td><td class="mono">Standard_D2ds_v6</td><td>SCSI <span class="arr">&rarr;</span> NVMe</td><td>In-place upgrade</td><td class="n">2</td><td class="n">0</td>'
    }

    It 'machines: grouped by wave, each with its result, and its evidence folded under it' {
        $s = [regex]::Match($script:html, '(?s)3</span> Machines.*?</section>').Value
        $s | Should -Match 'storefront<span class="w">2 machines &middot; 20:00&ndash;20:37'
        $s | Should -Match '<details><summary>Evidence: 4 readings, 2 same, 1 changed as planned, 1 not read</summary>'
        $s | Should -Match '<tr class="grp"><td colspan="4">Instance Metadata Service</td></tr>'
        $s | Should -Match '<td>Boot disk bus</td><td class="v">&mdash;</td><td class="v">NVMe</td><td><span class="pill quiet">Not read</span>'
        $s | Should -Match 'D2s_v4<span class="arr">&rarr;</span>D2s_v6' -Because 'a migrated machine shows where it went'
        @([regex]::Matches($s, '<details>')).Count | Should -Be 1 -Because 'only a machine with evidence gets the fold'
    }

    It 'exceptions: who, why, when and what next - for a restore, a rollback, anything that did not migrate' {
        $s = [regex]::Match($script:html, '(?s)4</span> Exceptions.*?</section>').Value
        $s | Should -Match 'prd-win-a</td><td><span class="pill quiet">Restored</span></td><td>Application owner request</td><td>operator@example.com</td><td>14 Oct 2026 22:41</td><td>Migrate the machine again in a new change window.</td>'
        $s | Should -Match 'Rolled back</span></td><td>A step failed, and the product restored the machine\.</td><td>The product</td>'
        $s | Should -Not -Match 'agent timeout' -Because 'the engine''s own message is not a sentence for a customer'
        $s | Should -Not -Match 'can-lin-a'
    }

    # REPORT-AUTO-1 REWROTE this: it held an empty "Report" row, the place the
    # "Produce the report" dialog's sign-off went. The engine writes the report
    # now and nobody signs it, so the row is gone; the decisions stay.
    It 'sign-off: every decision a person made, and no row for the report itself' {
        $s = [regex]::Match($script:html, '(?s)5</span> Sign-off.*?</section>').Value
        $s | Should -Match '<td>Plan</td><td>approver@example.com</td><td>13 Oct 2026, 16:02</td>'
        $s | Should -Match '<td>Wave billing</td>'
        $s | Should -Not -Match '<td>Report'
    }
}

Describe 'VERIFY-FP-1 part 3b: the report is safe to open' {
    It 'every value from the store is escaped' {
        $script:html | Should -Not -Match '<b>x</b>'
        $script:html | Should -Match 'prd-&lt;b&gt;x&lt;/b&gt;'
    }

    It 'nothing is loaded from anywhere, and nothing runs' {
        $css = InModuleScope VmMigrationFactory { $script:VmfReportCss }
        $css | Should -Not -Match '@import|url\('
        $script:html | Should -Not -Match '<script|<link|https?://'
    }

    It 'times read back from JSON as date values are still read as UTC, never through a culture' {
        InModuleScope VmMigrationFactory -Parameters @{ r = $script:record } {
            param($r)
            $round = $r | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
            $h = ConvertTo-VmfReportHtml -Record $round
            $h | Should -Match '14 Oct 2026, 20:00&ndash;23:10 UTC'
        }
    }
}

Describe 'VERIFY-FP-1 part 3b review: what the report says when the data is thin' {
    It 'a stop with a known reason gives that reason''s title and what to do' {
        InModuleScope VmMigrationFactory {
            $g = Get-VmfStopGuidance -Code 'permissionsMissing'
            $r = [ordered]@{ runId = 'x'; decisions = @(); machines = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/a'
                name = 'a'; wave = 'w'; path = 'A'; outcome = 'attention'; before = [ordered]@{ size = 'S1'; controller = 'SCSI' }; target = [ordered]@{ size = 'S2'; controller = 'NVMe' }; now = [ordered]@{ size = 'S1' }
                steps = @([ordered]@{ tsUtc = '2026-10-14T20:00:00Z'; state = 'PRECHECK'; outcome = 'fail'; reasonCode = 'permissionsMissing'; detail = '403 AuthorizationFailed on Microsoft.Compute/...' }) }) }
            $h = ConvertTo-VmfReportHtml -Record $r
            $h | Should -Match ([regex]::Escape([System.Net.WebUtility]::HtmlEncode($g.title)))
            $h | Should -Match ([regex]::Escape([System.Net.WebUtility]::HtmlEncode($g.whatToDo)))
            $h | Should -Not -Match 'AuthorizationFailed'
        }
    }

    # LAB-UX-1: whatToDo no longer says to try again - the Migrations page adds
    # the line for the reason's retry kind. The record put whatToDo alone in its
    # "next" column, so a rolled-back machine's record stopped saying to run it
    # again. It takes the same line, from the same table.
    It 'the next step in the record carries the retry line for the reason''s kind' {
        InModuleScope VmMigrationFactory {
            $lines = (Get-VmfStopReasons).retryLines
            foreach ($code in 'rolledBack', 'safetyCopyMissing', 'diskTypeChangeLimit', 'bootFailedAfterConversion') {
                $g = Get-VmfStopGuidance -Code $code
                $outcome = if ($code -eq 'rolledBack') { 'rolledBack' } else { 'attention' }
                $r = [ordered]@{ runId = 'x'; decisions = @(); machines = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/a'
                    name = 'a'; wave = 'w'; path = 'A'; outcome = $outcome; before = [ordered]@{ size = 'S1'; controller = 'SCSI' }; target = [ordered]@{ size = 'S2'; controller = 'NVMe' }; now = [ordered]@{ size = 'S1' }
                    steps = @([ordered]@{ tsUtc = '2026-10-14T20:00:00Z'; state = 'VALIDATING'; outcome = 'fail'; reasonCode = $code; detail = 'x' }) }) }
                $h = ConvertTo-VmfReportHtml -Record $r
                $want = [System.Net.WebUtility]::HtmlEncode("$($g.whatToDo) $($lines.($g.retry))")
                $h | Should -Match ([regex]::Escape("<td>$want</td>")) -Because "$code's next step is its whatToDo and its retry line, in one cell"
            }
        }
    }

    It 'every retry kind a reason uses has its line, and the page reads the same table' {
        InModuleScope VmMigrationFactory {
            $t = Get-VmfStopReasons
            foreach ($r in @($t.reasons)) {
                [string]$t.retryLines.($r.retry) | Should -Not -BeNullOrEmpty -Because "$($r.code) has retry '$($r.retry)'"
            }
        }
        $page = (Get-VmfPageSource -Path (Join-Path $PSScriptRoot '..' '..' 'src' 'dashboard' 'migrations.html'))
        $page | Should -Match 'retryLines = sr\.retryLines' -Because 'one table, not a second copy of the words in the page'
        $page | Should -Not -Match 'whyRetryAfterFix'
    }

    It 'a controller nobody read is "Not read" - never a guess - and one move is one row' {
        InModuleScope VmMigrationFactory {
            $m = { param($n, $c) [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$n"; name = $n; wave = 'w'; path = 'A'; outcome = 'notStarted'
                before = [ordered]@{ size = 'S1'; controller = $c }; target = [ordered]@{ size = 'S2'; controller = 'NVMe' }; now = [ordered]@{ size = 'S1' }; steps = @() } }
            $h = ConvertTo-VmfReportHtml -Record ([ordered]@{ runId = 'x'; decisions = @(); machines = @((& $m 'a' $null), (& $m 'b' '')) })
            $moves = [regex]::Match($h, '(?s)2</span> Moves.*?</section>').Value
            @([regex]::Matches($moves, '<tr><td class="mono">S1</td>')).Count | Should -Be 1
            $moves | Should -Match 'Not read <span class="arr">&rarr;</span> NVMe</td><td>In-place upgrade</td><td class="n">2</td>'
            $h | Should -Match '2 machines &middot; 1 wave &middot; 1 subscription<'
        }
    }

    It 'waves are in the order they ran, not by name' {
        $m = [regex]::Match($script:html, '(?s)3</span> Machines.*?</section>').Value
        $m.IndexOf('>storefront<') | Should -BeLessThan $m.IndexOf('>billing<')
    }

    It 'a title the caller gave is the heading' {
        InModuleScope VmMigrationFactory -Parameters @{ r = $script:record } {
            param($r)
            ConvertTo-VmfReportHtml -Record $r -Title 'Wave billing report' | Should -Match '<h1>Wave billing report</h1>'
        }
    }
}