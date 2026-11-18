#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
ASSESS-LINK-1: nothing outside the browser stopped an assessment being deleted
from under the migration planned from it.

The rule lived only as a disabled button on the Assessments page. The discard
it guarded checked only that the run was not working on machines, so a direct
call - or a page that read a short listing - deleted the assessment and its
signed review, and the migration went on naming a record that no longer
existed. The owner met the end of it: the migration stayed, and the project
could not be emptied.

And the tidy-up of abandoned scans had the same hole from the other side: an
assessment never has a plan of its own, so after 30 days it looked abandoned -
including one a live migration was planned from.
#>
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:LinkRun {
        param($Root, [string]$Id, [ValidateSet('assessment', 'migration')][string]$Kind, [string]$From, [int]$AgeDays = 0)
        $parts = $Id -split '/'
        $project = if ($parts.Count -gt 1) { $parts[0] } else { $null }
        $path = "$Root/$Id"
        InModuleScope VmMigrationFactory -Parameters @{ p = $path; id = $parts[-1]; k = $Kind; f = $From; pr = $project } {
            Initialize-VmfRun -RunPath $p -RunId $id -Kind $k -FromAssessment $f -Project $pr | Out-Null
        }
        if ($AgeDays) {
            $m = Get-Content (Join-Path $path 'run.json') -Raw | ConvertFrom-Json
            $m.createdUtc = (Get-Date).ToUniversalTime().AddDays(-$AgeDays).ToString('o')
            $m | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $path 'run.json')
        }
        $path
    }
    function Global:LinkProject {
        param($Root, [string]$Id)
        New-VmfProject -StorePath $Root -ProjectId $Id -Name $Id `
            -OnBehalfOf @{ Identity = 'sam@example.com'; TenantId = 't1' } | Out-Null
    }
    function Global:LinkOperator {
        $claims = @(@{ typ = 'preferred_username'; val = 'oper@example.com' }, @{ typ = 'roles'; val = 'Vmf.Operator' })
        $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
        ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
    }
}
AfterAll { Remove-Item 'function:\LinkRun', 'function:\LinkProject', 'function:\LinkOperator' -ErrorAction SilentlyContinue }

Describe 'ASSESS-LINK-1: the engine refuses to delete an assessment a migration was planned from' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-link-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        LinkProject $script:root 'estate'
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force } }

    It 'refuses, and names the migration' {
        $a = LinkRun $script:root 'estate/scan-1' assessment
        LinkRun $script:root 'estate/scan-1-migration-1' migration 'scan-1' | Out-Null
        { Remove-VmfRun -RunPath $a -Reason 'tidy' -RemovedBy 'sam@example.com' -KeepSafetyCopies -Confirm:$false } |
            Should -Throw "*still holds 1 migration(s) planned from it: estate/scan-1-migration-1*"
        Test-Path (Join-Path $a 'run.json') | Should -BeTrue -Because 'nothing was deleted'
    }

    It 'finds a migration planned into a DIFFERENT project - the bare id cannot say which' {
        LinkProject $script:root 'other'
        $a = LinkRun $script:root 'estate/scan-1' assessment
        LinkRun $script:root 'other/scan-1-migration-1' migration 'scan-1' | Out-Null
        { Remove-VmfRun -RunPath $a -Reason 'tidy' -RemovedBy 'sam@example.com' -KeepSafetyCopies -Confirm:$false } |
            Should -Throw '*other/scan-1-migration-1*'
    }

    It 'works for runs outside any project too' {
        $a = LinkRun $script:root 'scan-2' assessment
        LinkRun $script:root 'scan-2-migration-1' migration 'scan-2' | Out-Null
        { Remove-VmfRun -RunPath $a -Reason 'tidy' -RemovedBy 'sam@example.com' -KeepSafetyCopies -Confirm:$false } |
            Should -Throw '*scan-2-migration-1*'
    }

    It 'lets it go once the migration is gone, and always lets an unused one go' {
        $a = LinkRun $script:root 'estate/scan-1' assessment
        $m = LinkRun $script:root 'estate/scan-1-migration-1' migration 'scan-1'
        Remove-VmfRun -RunPath $m -Reason 'tidy' -RemovedBy 'sam@example.com' -KeepSafetyCopies -Confirm:$false | Out-Null
        (Remove-VmfRun -RunPath $a -Reason 'tidy' -RemovedBy 'sam@example.com' -KeepSafetyCopies -Confirm:$false).Removed |
            Should -BeTrue
    }

    It 'does not mistake a migration from ANOTHER assessment for this one' {
        $a = LinkRun $script:root 'estate/scan-1' assessment
        LinkRun $script:root 'estate/scan-9-migration-1' migration 'scan-9' | Out-Null
        (Remove-VmfRun -RunPath $a -Reason 'tidy' -RemovedBy 'sam@example.com' -KeepSafetyCopies -Confirm:$false).Removed |
            Should -BeTrue
    }

    It 'the service answers 400 with the names, and writes nothing to the log first' {
        $a = LinkRun $script:root 'estate/scan-1' assessment
        LinkRun $script:root 'estate/scan-1-migration-1' migration 'scan-1' | Out-Null
        { Invoke-VmfFacadeDiscardRun -Principal (LinkOperator) -StorePath $a -Note 'tidy' } |
            Should -Throw '400: *still holds 1 migration(s)*'
        $log = Join-Path $a 'logs' 'events.jsonl'
        if (Test-Path $log) { Get-Content $log -Raw | Should -Not -Match 'discarded by' -Because 'it was not discarded' }
    }
}

Describe 'ASSESS-LINK-1: the tidy-up keeps an old assessment a migration was planned from' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-link-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        LinkProject $script:root 'estate'
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force } }

    It 'keeps it, says why, and still removes a truly abandoned one' {
        LinkRun $script:root 'estate/scan-used' assessment -AgeDays 60 | Out-Null
        $m = LinkRun $script:root 'estate/scan-used-migration-1' migration 'scan-used'
        InModuleScope VmMigrationFactory -Parameters @{ p = $m } {
            Write-VmfStoreJson -RunPath $p -RelPath 'plan.json' -Document @{ schemaVersion = 4; entries = @() } -Depth 6
        }
        LinkRun $script:root 'estate/scan-alone' assessment -AgeDays 60 | Out-Null

        $r = Remove-VmfAbandonedRuns -StorePath $script:root -RemovedBy 'sam@example.com' -Confirm:$false
        @($r.Removed.Id) | Should -Be @('estate/scan-alone')
        (@($r.Kept) | Where-Object Id -EQ 'estate/scan-used').Why | Should -Be 'a migration was planned from it'
    }
}
