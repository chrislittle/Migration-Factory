@{
    RootModule        = 'VmMigrationFactory.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '7f3f3a52-9c1e-4b8a-b9d0-52c1f6b0a9e4'
    Author            = 'Chris Little'
    Copyright         = 'Copyright 2026 Chris Little. Licensed under the Apache License, Version 2.0.'
    Description       = 'Fleet-scale Azure VM size migration factory, from older series to v5, v6 and v7 (SCSI to NVMe): assessment, wave orchestration, reservation, validation, rollback.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        # PROJECT-1: the container an assessment and its migrations live in.
        'New-VmfProject',
        'Get-VmfProject',
        'Remove-VmfProject',
        'Remove-VmfAbandonedRuns',
        'Get-VmfDiskArchitecture',
        'ConvertFrom-VmfGuestOutput',
        'Get-VmfGuestScript',
        'Invoke-VmfAssessment',
        'New-VmfPlan',
        # ADVISOR-1: the target options for each machine, before the waves.
        'New-VmfTargetAdvice',
        # MACHINE-PICK-1: which machines the migration moves, before their targets.
        'Set-VmfMachineChoice',
        'Set-VmfTargetChoice',
        # WAVE-MIX-2: one machine's series after planning.
        'Set-VmfMachineTarget',
        'Set-VmfWavePlan',
        'Restore-VmfVm',
        # SWAP-REFUSED-AFTER-STOP-1: Finish the rollback / Finish the restore.
        'Complete-VmfDataDiskSwap',
        'Restore-VmfMachinePower',
        # RESTORE-EARLIER-DELETE-1: Delete these disks, after a restore that kept them.
        'Remove-VmfRestoreEarlierDisks',
        # MADE-DISK-DELETE-1: Delete these disks now, the disks a put-back made that nothing uses.
        'Remove-VmfMadeDisks',
        # VOLUMES-RESTORE-MIGRATED-1: Check the volumes, for a machine whose record owes the check.
        'Invoke-VmfVolumesCheck',
        'Confirm-VmfRunAcknowledgement',
        'Confirm-VmfWaveOptions',
        'Set-VmfWaveSchedule',
        'Get-VmfWaveSchedule',
        'Remove-VmfWaveSchedule',
        'Test-VmfWaveWindow',
        'Test-VmfQuota',
        'Test-VmfQuotaAndReservation',
        'Request-VmfQuota',
        'New-VmfReport',
        'Start-VmfWave',
        'New-VmfWaveReservation',
        'Invoke-VmfWaveCloseOut',
        'Remove-VmfCapacityReservations',
        'Remove-VmfExpiredSafetyCopies',
        'Remove-VmfRun',
        'Stop-VmfRun',
        # SKIP-ONE-1: leave ONE machine out, so the rest of the wave finishes.
        'Skip-VmfVm',
        'Resolve-VmfDecision',
        # DECIDE-1: which plan lever carries a stop's decision, and whether
        # accepting it needs the approver. The facade calls it to enforce
        # the role on the control the machine's panel offers.
        'Get-VmfDecisionLevers',
        'Clear-VmfWaveHalt',
        'Approve-VmfWave',
        'Approve-VmfPlan',
        'Export-VmfMigrationRecord',
        'Get-VmfMigrationRecord',
        'Approve-VmfAssessment',
        # VERSION-1: which build this is.
        'Get-VmfVersion'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Azure', 'Migration', 'NVMe')
            ProjectUri = 'https://github.com/chrislittle/Migration-Factory'
            LicenseUri = 'https://github.com/chrislittle/Migration-Factory/blob/main/LICENSE'
        }
    }
}
