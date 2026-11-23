@{
    RootModule        = 'FacadeCore.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '7c1f4a3e-9b2d-4e8f-a1c6-5d0e8b7f2a91'
    Author            = 'VmMigrationFactory'
    Description       = 'S3-1: Stage 3 facade core - Easy Auth principal parsing, app-role enforcement, and API response shaping over the run-store contract. Pure logic; the VmMigrationFactory module provides all store access.'
    PowerShellVersion = '7.2'
    FunctionsToExport = @(
        # BODY-HASH-1: one conversion for a request body, not one per route.
        'ConvertTo-VmfHashtable',
        'ConvertFrom-VmfClientPrincipal',
        'Get-VmfDocumentVersionHeaders',
        'Assert-VmfFacadeRole',
        'Get-VmfFacadeRunIds',
        'Test-VmfFacadeRunFolder',
        'Get-VmfFacadeRunStorePath',
        'Get-VmfFacadeStorePath',
        'Get-VmfFacadePlanPath',
        # STORE-READ-1: the browser stops reading blob storage directly
        'Resolve-VmfFacadeStoreKey',
        # RECORDS-VIEWER-READ-1: the folders the product keeps are the Admin's.
        'Assert-VmfFacadeStoreKeyReadable',
        'Select-VmfFacadeReadableStoreKeys',
        'ConvertFrom-VmfFacadeBlobListing',
        # PAGE-LOAD-1: one listing for store/list and store/docs, and the
        # documents a page draws, read in one call.
        'Get-VmfFacadeContainerUri',
        'Get-VmfFacadeStoreListing',
        'Get-VmfFacadeStoreDocs',
        'Get-VmfFacadeRunSummary',
        'Get-VmfFacadeScopeList',
        'Get-VmfFacadeResourceGroupList',
        # TEMP-DISK-PREVIEW-1: the state of the preview feature, for the targets step.
        'Get-VmfFacadePreviewFeature',
        'Invoke-VmfFacadeApprove',
        'Invoke-VmfFacadeApprovePlan',
        'Invoke-VmfFacadeContinuePlan',
        'Invoke-VmfFacadeExportMigrationRecord',
        'Invoke-VmfFacadeListMigrationRecords',
        'Invoke-VmfFacadeGetKeptMigrationRecord',
        'Invoke-VmfFacadeSetWaves',
        # WAVE-MIX-2: one machine's size series after planning.
        'Invoke-VmfFacadeSetMachineTarget',
        'Invoke-VmfFacadeTidyAbandonedRuns',
        'Invoke-VmfFacadeSchedule',
        'Invoke-VmfFacadeReleaseDueSchedules',
        'Invoke-VmfFacadeResumeStalledWaves',
        'Invoke-VmfFacadeResumeStalledPutBacks',
        'Invoke-VmfFacadeResumeStalledVolumeChecks',
        'Invoke-VmfFacadeRemoveEndedWaveHolds',
        # ODCR-STATUS-1: the five-minute pass reads a stuck capacity reservation from Azure.
        'Invoke-VmfFacadeReadReservingClaims',
        # TIMER-EXEC-LIST-1: the five-minute pass keeps one list of the engine's executions.
        'Start-VmfFacadeEngineListPass',
        'Stop-VmfFacadeEngineListPass',
        # FACADE-TIMER-QUEUE-1: a run's machine records, read once a pass.
        'Get-VmfFacadeRunStateDocs',
        # SCHEDULE-PASS-DUE-1: a run of the due record that an engine job still runs for stays in it.
        'Test-VmfFacadeRunJobRunning',
        # SCAN-FAIL-SHOWN-1: the five-minute pass ends the wait of a scan whose job ended with no answer.
        'Invoke-VmfFacadeEndSilentScan',
        'Invoke-VmfFacadeHalt',
        'Invoke-VmfFacadeClearHalt',
        'Invoke-VmfFacadeResolve',
        # SKIP-ONE-1: leave ONE machine out, so the rest of the wave finishes.
        'Invoke-VmfFacadeSkipVm',
        'Invoke-VmfFacadeStartEngine',
        'Invoke-VmfFacadeAcknowledge',
        'Invoke-VmfFacadeAcceptWaveOptions',
        'Invoke-VmfFacadeDiscardRun',
        'Invoke-VmfFacadeDeleteProject',
        'Invoke-VmfFacadeStopRun',
        'Get-VmfFacadeWaveCapacity',
        'Invoke-VmfFacadeApproveAssessment',
        # ADVISOR-1: the chosen target for each machine.
        'Invoke-VmfFacadeSetTargets',
        # MACHINE-PICK-1: the machines the migration moves.
        'Invoke-VmfFacadeSetMachines',
        # PROJECT-1
        'Invoke-VmfFacadeListProjects',
        'Invoke-VmfFacadeCreateProject',
        # VERSION-1
        'Get-VmfFacadeVersion',
        # REPORT-THEME-1: the report's stylesheet, for the migration record
        'Get-VmfFacadeReportStyle',
        # SCALE-UX-1
        'Get-VmfFacadeEngineResources',
        'Get-VmfFacadeWaveContainers',
        # MACHINES-AT-ONCE-RANGE-1: the one read of a wave's machines at once.
        'Get-VmfFacadeWaveThrottle',
        'Get-VmfFacadeEngineCapacity',
        'Assert-VmfFacadeEngineCapacity',
        'Get-VmfFacadeEngineJob',
        'Test-VmfFacadeConsumptionOnly',
        # PERF-TELEMETRY-1: the record of each function's store and ARM calls
        'Start-VmfFacadeCallTimings',
        'Complete-VmfFacadeCallTimings'
    )
}
