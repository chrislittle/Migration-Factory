#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REBUILD-ACCEPT-1: say what a rebuild breaks on this machine, and accept it
# per machine.
#
# THE DEFECT, measured in the lab on 2026-11-01
# (docs/research/rebuild-impact-2026-11-01.md): a rebuild around the same disks
# deletes the VM and creates it again. Site Recovery stops replicating with no
# error for about 23 minutes; the SQL virtual machine resource is deleted;
# every extension is removed; the data collection rule associations go with
# the VM. The product named only the system-assigned identity, and a rebuild
# of a machine with none went ahead on the wave setting alone.
#
# Now (2026-11-01): the scan reads, with the access it already has, the
# VM extensions and the SQL virtual machine resource; the acceptance of a
# rebuild lists ONLY what was found on that machine; and PRECHECK refuses a
# rebuild that no acceptance names - the identity's gate, extended, one gate.
#
# REBUILD-REMOVE-ACCEPT-1: the acceptances and that gate are gone with the
# rebuild (RebuildRemoveAccept.Tests.ps1 holds the refusal that replaced them).
# REBUILD-REMOVE-ROLE-1: the rule that made the follow-ups is gone too.
# REBUILD-REMOVE-SCAN-EXT-1: the scan's read of the extensions is gone too
# (RebuildRemoveScanExt.Tests.ps1). OLD-VERSION-READERS-REMOVE-1: so are the
# words of a follow-up and the run report section that repeated them from a
# line an earlier version wrote - nobody holds such a run (2026-11-11).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_WaveGate.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'rba'

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
    $script:vmId = "$($script:sub)app-01"

    function Global:RbRun {
        $rp = Join-Path $script:temp "rb-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'rb' | Out-Null }
        $rp
    }
    function Global:RbEvents([string]$RunPath) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath } { param($rp) @(Read-VmfEvents -RunPath $rp) }
    }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\RbRun', 'function:\RbEvents' -ErrorAction SilentlyContinue
}

Describe 'REBUILD-REMOVE-PLAN-1: the plan carries nothing a rebuild would delete' {
    # REBUILD-REMOVE-PLAN-1 (plan-entry v29): no plan rebuilds a machine, so the plan
    # no longer carries what a rebuild would delete, and no acceptance reads it.
    It 'the plan no longer carries what the scan read onto each entry' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfPlan.ps1')
        $code | Should -Not -Match 'rebuildLinks'
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-1: the run report has no section for the follow-ups of a rebuild' {
    It 'the words and the section are gone, and the report does not ask for them' {
        foreach ($n in 'Get-VmfRebuildFollowUpText', 'Get-VmfRebuildFollowUpReportHtml', 'Get-VmfRebuildAlwaysLine', 'Get-VmfPatchModesUrl') {
            InModuleScope VmMigrationFactory -Parameters @{ n = $n } { param($n) Get-Command $n -ErrorAction SilentlyContinue } | Should -BeNullOrEmpty -Because $n
        }
        $report = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfReport.ps1')
        $report | Should -Not -Match 'What to do after a rebuild|rebuildFollowUps'
    }
}