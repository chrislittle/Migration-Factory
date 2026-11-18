#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RUN-DELETE-RESERVE-1: deleting a migration must not delete the records of
# its reservations while they bill.
#
# Found by the independent review of WAVE-EDIT-RESERVE-1. Remove-VmfRun - the
# one function behind discard, the abandoned-run tidy-up and (through it)
# project delete - deleted the run's whole store prefix, capacity claims
# included, and Test-VmfRunDiscardable never looked at them. A migration that
# reserved capacity and never started could be deleted while its reservation
# kept billing with nothing in the product pointing at it.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:RdRun([string]$ClaimState) {
        $store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rd-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $run = Join-Path $store 'run-x'
        $vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $run; vm = $vm; st = $ClaimState } {
            Initialize-VmfRun -RunPath $rp -RunId 'run-x' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{
                schemaVersion = 8; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'w1'; path = 'A' }) })
            if ($st) {
                Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/w1-d2ds.json' -Depth 12 -Document ([ordered]@{
                    schemaVersion = 8; wave = 'w1'; region = 'centralus'; size = 'Standard_D2ds_v6'; count = 1; state = $st })
            }
        }
        @{ Store = $store; Run = $run }
    }
}
AfterAll { Remove-Item 'function:\RdRun' -ErrorAction SilentlyContinue }

Describe 'RUN-DELETE-RESERVE-1: a migration holding a reservation that bills is not deleted' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSignedInIdentity { @{ Identity = 'operator@example.com' } }
    }
    AfterEach { if ($script:fx -and (Test-Path $script:fx.Store)) { Remove-Item $script:fx.Store -Recurse -Force } }

    It 'refuses while a wave holds a reservation <State>, and deletes nothing' -ForEach @(
        @{ State = 'RESERVED' }, @{ State = 'CONSUMED' }) {
        $script:fx = RdRun $State
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -Confirm:$false } |
            Should -Throw "400: Wave w1 has an on-demand capacity reservation in Azure ($State). Release it on the wave, then delete the migration."
        Test-Path (Join-Path $script:fx.Run 'capacity' 'w1-d2ds.json') | Should -BeTrue
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue
    }

    It 'one still being made says to wait - the wave card has no Release for it, so it never points at one' {
        $script:fx = RdRun 'RESERVING'
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -Confirm:$false } |
            Should -Throw '400: Wave w1 has an on-demand capacity reservation that Azure is still making (RESERVING). Wait until the wave shows Reserved*'
        Test-Path (Join-Path $script:fx.Run 'capacity' 'w1-d2ds.json') | Should -BeTrue
    }

    It 'asks again just before the records go: a reserve job that writes a claim mid-delete stops it' {
        # Between the first question and the prefix delete come the migration
        # record, safety copies and machine claims - minutes on a large run.
        $script:fx = RdRun 'QUOTA_VERIFIED'
        Mock -ModuleName VmMigrationFactory New-VmfMigrationRecord {
            & (Get-Module VmMigrationFactory) { param($rp)
                Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/w1-late.json' -Depth 12 -Document ([ordered]@{
                    schemaVersion = 8; wave = 'w1'; region = 'centralus'; size = 'Standard_D4ds_v6'; count = 1; state = 'RESERVED' })
            } $RunPath
        }
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -Confirm:$false } | Should -Throw '400: Wave w1 has an on-demand capacity reservation in Azure (RESERVED)*'
        Test-Path (Join-Path $script:fx.Run 'capacity' 'w1-late.json') | Should -BeTrue
    }

    It 'refuses before the migration record is written for a deletion that does not happen' {
        $script:fx = RdRun 'RESERVED'
        { Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -Confirm:$false } | Should -Throw '400:*'
        @(Get-ChildItem (Join-Path $script:fx.Store 'vmf-records') -Recurse -File -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'a quota check or a RELEASED record bills nothing: the migration may go' -ForEach @(
        @{ State = 'QUOTA_VERIFIED' }, @{ State = 'RELEASED' }) {
        $script:fx = RdRun $State
        (Remove-VmfRun -RunPath $script:fx.Run -Reason 'x' -Confirm:$false).Removed | Should -BeTrue
        Test-Path $script:fx.Run | Should -BeFalse
    }

    It 'the service refuses with a 400, and writes no "discarded by" for a deletion that did not happen' {
        $claims = @(@{ typ = 'preferred_username'; val = 'operator@example.com' }, @{ typ = 'roles'; val = 'Vmf.Operator' })
        $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
        $principal = ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
        $script:fx = RdRun 'RESERVED'
        { Invoke-VmfFacadeDiscardRun -Principal $principal -StorePath $script:fx.Run -Note 'not needed' } |
            Should -Throw '400: Wave w1 has an on-demand capacity reservation in Azure (RESERVED)*'
        $events = InModuleScope VmMigrationFactory -Parameters @{ p = $script:fx.Run } { Read-VmfEvents -RunPath $p -Step 'run' }
        @($events | Where-Object { $_.detail -match 'discarded by' }).Count | Should -Be 0
        Test-Path (Join-Path $script:fx.Run 'plan.json') | Should -BeTrue
    }
}

Describe 'RUN-DELETE-RESERVE-1: the abandoned-run tidy-up keeps such a run, and says why' {
    AfterEach { if ($script:fx -and (Test-Path $script:fx.Store)) { Remove-Item $script:fx.Store -Recurse -Force } }

    It 'keeps it rather than stopping the whole tidy-up' {
        # A run the tidy-up removes has no plan, and quota records need one - so
        # this cannot happen today. It is kept, not thrown, if it ever does.
        $script:fx = RdRun 'RESERVED'
        Remove-Item (Join-Path $script:fx.Run 'plan.json')
        $manifest = Get-Content (Join-Path $script:fx.Run 'run.json') -Raw | ConvertFrom-Json
        $manifest.createdUtc = (Get-Date).ToUniversalTime().AddDays(-60).ToString('o')
        $manifest | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:fx.Run 'run.json')
        $r = Remove-VmfAbandonedRuns -StorePath $script:fx.Store -RemovedBy 'operator@example.com' -Confirm:$false
        @($r.Removed).Count | Should -Be 0
        (@($r.Kept) | Where-Object Id -EQ 'run-x').Why | Should -Be 'it holds a capacity reservation that bills'
    }
}
