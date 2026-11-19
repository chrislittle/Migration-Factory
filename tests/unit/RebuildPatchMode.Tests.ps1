#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REBUILD-PATCH-MODE-1 (1.0): every rebuild of a machine with the patch mode
# AutomaticByPlatform failed, and rolled back.
#
# MEASURED in the lab on 2026-11-04: a Windows Server 2022 machine with the
# patch mode AutomaticByPlatform, moved with a rebuild around the same disks.
# After the create, the PATCH of its patch settings was refused (quote
# redacted to the test machine's name):
#   400 InvalidParameter "The selected VM image is not supported for VM Guest
#   patch operations." target windowsConfiguration.patchSettings.patchMode
# The move failed after the definition (and the system-assigned identity) was
# deleted. The rollback got the same refusal, wrote a note that said to set
# AutomaticByPlatform again, which Azure refuses there, and the activity showed
# the refusal a second time as a red failure line.
#
# Microsoft (learn.microsoft.com/azure/virtual-machines/automatic-vm-guest-patching):
# AutomaticByPlatform "is only supported for VMs that are created using the
# supported OS platform images", and a VM made again without its image
# reference "may no longer qualify". A rebuild creates the machine around its
# attached OS disk, with no image reference.
#
# REBUILD-REMOVE-ROLE-1: no rebuild is left, so the steps below are gone; what
# stays is Verifying and the contracts. Before that: a rebuild never asked for AutomaticByPlatform; the refusal "not
# supported for VM Guest patch operations" of another patch setting is said
# and the step goes on; a refusal the step goes on from writes one line, never
# a red failure line too; and Verifying does not fail a rebuilt machine for a
# patch setting CONVERTING already read back or said it could not set.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'rpm'

    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1'
    function Global:RpmRun {
        $rp = Join-Path $script:temp "rpm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'rpm' | Out-Null }
        $rp
    }
    function Global:RpmCapture([string]$Mode = 'AutomaticByPlatform', [string]$Assess = 'ImageDefault') {
        [pscustomobject]@{ patchSettings = [pscustomobject]@{ os = 'Windows'; patchMode = $Mode; assessmentMode = $Assess; enableHotpatching = $false
                rebootSetting = 'IfRequired'; bypassPlatformSafetyChecksOnUserSchedule = $true } }
    }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\RpmRun', 'function:\RpmCapture' -ErrorAction SilentlyContinue
}

# REBUILD-REMOVE-ROLE-1: the patch settings after a rebuild (Invoke-VmfRebuildPatchSettings,
# Get-VmfRebuildPatchRequest, Test-VmfPatchImageRefusal, Set-VmfVmPatchSettings) are gone
# with the last rebuild. Their tests were here.

Describe 'REBUILD-PATCH-MODE-1: Verifying a rebuilt machine' {
    BeforeAll {
        function Global:RpmLive([string]$Mode) {
            $os = if ($Mode) { [pscustomobject]@{ WindowsConfiguration = [pscustomobject]@{ PatchSettings = [pscustomobject]@{ PatchMode = $Mode; AssessmentMode = 'ImageDefault' } } } } else { $null }
            [pscustomobject]@{ OSProfile = $os }
        }
    }
    AfterAll { Remove-Item 'function:\RpmLive' -ErrorAction SilentlyContinue }

    # REBUILD-REMOVE-ENGINE-1: no move rebuilds, so Verifying has no rebuilt variant (-Rebuilt, Get-VmfStartedPath). Its tests were here.
    It 'a machine moved in place keeps every patch setting: none is a failure' {
        $r = InModuleScope VmMigrationFactory -Parameters @{ cap = (RpmCapture); vm = (RpmLive '') } {
            param($cap, $vm) Test-VmfRebuildSettingsFidelity -Captured $cap -Live (Get-VmfRebuildSettingsFromVm -Vm $vm) }
        $r.Ok | Should -BeFalse
    }

}

Describe 'REBUILD-PATCH-MODE-1: assessment v8, the contract' {
    It 'OLD-VERSION-READERS-REMOVE-1: the acceptance of a wave records no follow-up of a rebuild' {
        InModuleScope VmMigrationFactory { Get-VmfWaveOptionsAcceptanceSchemaVersion } | Should -Be 9
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'wave-options-acceptance.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $s.properties.PSObject.Properties.Name | Should -Not -Contain 'rebuild'
    }
    It 'the migration note says what changed and how an older assessment reads' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match '## assessment v7 -> v8, wave-options-acceptance v5 -> v6 \(2026-11-04, REBUILD-PATCH-MODE-1\)'
    }
}
