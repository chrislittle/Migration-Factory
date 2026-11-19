#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SEC-1 / F10 - an action names the resource it acts on.
#
# Rule since 2026-09-06: every action in the system addresses the resource
# ID, the one string that is unique in Azure.
#
# A resource group and a name are unique only INSIDE one subscription, and the
# engine container signs in with `Connect-AzAccount -Identity` naming none. So
# a command that reduces an id to that pair acts on whatever the ambient
# context happens to resolve - which ENGINE-SUB-1 recorded reproducing against
# two real subscriptions, and then fixed for the wave path alone.
#
# There are two right answers, and which one applies is not a matter of taste:
#
#   1. Address the resource THROUGH its id. No ambient context is consulted,
#      so it is correct everywhere - including inside the service, which
#      serves several requests on one PowerShell worker, where a process-wide
#      context switch would be a race between them. The snapshot operations
#      take this route because the service reaches them.
#
#   2. Pin the machine's own subscription for the duration and put it back.
#      Only safe where one operation owns the process, which is true of the
#      engine container and false of the service.
#
# These tests derive who needs which, rather than listing them: a list only
# guards the commands somebody remembered to add to it.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }
    $script:opsDir = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops'
    $script:publicDir = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public'

    # Comments explain the rule and quote the names it is about, so every
    # check below reads the CODE. This trap was walked into three times in
    # one change: an assertion that matches its own explanation passes
    # exactly while somebody is still explaining the defect.
    #
    # COMMENT-TRAP-1: this file carried its OWN Get-VmfCodeOnly, under that
    # exact name, and it dropped lines beginning with a hash - so a trailing
    # comment walked past it. The shared one goes through the PowerShell
    # parser. Two definitions of one rule is how the two come to disagree.
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    function Global:Get-VmfFunctionAst([string]$File) {
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$errors)
        if ($errors) { throw "$File does not parse: $($errors[0].Message)" }
        $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    }

    # An operations function that addresses a resource by group and name, and
    # is never told which subscription that pair belongs to.
    $script:ambientOps = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($file in Get-ChildItem $script:opsDir -Filter '*.ps1') {
        foreach ($fn in Get-VmfFunctionAst $file.FullName) {
            $params = @($fn.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            if (($params -contains 'ResourceGroupName') -and -not ($params -contains 'SubscriptionId')) {
                $null = $script:ambientOps.Add($fn.Name)
            }
        }
    }

    # Which exported commands reach one.
    $script:callersNeedingCare = @{}
    foreach ($file in Get-ChildItem $script:publicDir -Filter '*.ps1') {
        $text = Get-Content $file.FullName -Raw
        $code = Get-VmfCodeOnly -Language PowerShell -Text $text
        $hits = @($script:ambientOps | Where-Object { $code -match "\b$([regex]::Escape($_))\b" })
        if ($hits.Count) { $script:callersNeedingCare[$file.BaseName] = $hits }
    }
}
AfterAll {
    Remove-Item 'function:\Get-VmfFunctionAst' -ErrorAction SilentlyContinue
    Remove-Item 'function:\Get-VmfCodeOnly' -ErrorAction SilentlyContinue
}

Describe 'SEC-1 / F10: an action names the subscription it acts in' {

    It 'found the operations that address a resource by group and name' {
        # A derived check that derives nothing passes everything.
        $script:ambientOps.Count | Should -BeGreaterThan 10 -Because 'this is the surface the rule exists for'
    }

    It 'every exported command that reaches one pins the subscription first, and puts it back' {
        $bad = foreach ($name in $script:callersNeedingCare.Keys) {
            $file = Join-Path $script:publicDir "$name.ps1"
            $code = Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $file -Raw)
            if ($code -notmatch 'Assert-VmfResourceId') { "$name never checks the id carries a subscription" }
            if ($code -notmatch 'Use-VmfSubscriptionContext') { "$name calls $($script:callersNeedingCare[$name] -join ', ') without pinning the subscription" }
            # The restore must be in a finally, not merely present: a restore
            # on the happy path only is a leaked context on every failure.
            $inFinally = $false
            foreach ($fn in Get-VmfFunctionAst $file) {
                foreach ($try in $fn.FindAll({ param($node) $node -is [System.Management.Automation.Language.TryStatementAst] }, $true)) {
                    if ($try.Finally -and (Get-VmfCodeOnly -Language PowerShell -Text $try.Finally.Extent.Text) -match 'Restore-VmfSubscriptionContext') { $inFinally = $true }
                }
            }
            if (-not $inFinally) { "$name does not put the context back in a finally" }
        }
        $bad -join ' | ' | Should -BeNullOrEmpty
    }

    It 'and the service never calls one of those commands in its own process' {
        # The pin is process-wide. That is safe in the engine, which runs ONE
        # operation per container and exits, and unsafe in the service, which
        # serves several requests on one PowerShell worker. So a command the
        # service calls in-process must reach Azure by resource id instead.
        $facadeDir = Join-Path $script:repoRoot 'src' 'facade'
        $facadeText = Get-VmfCodeOnly -Language PowerShell -Text ((Get-ChildItem $facadeDir -Filter '*.ps*1' -Recurse | Get-Content -Raw) -join "`n")
        $inProcess = foreach ($name in $script:callersNeedingCare.Keys) {
            if ($facadeText -match "\b$([regex]::Escape($name))\b") { $name }
        }
        $inProcess -join ', ' | Should -BeNullOrEmpty -Because 'a process-wide context switch inside the service is a race between concurrent requests'
    }
}

Describe 'BOUNDARY-3: the rule reaches PRIVATE callers too' {

    # The Describe above derives which EXPORTED commands reach an operation
    # that addresses a resource by group and name, and checks each one pins the
    # subscription. It reads Public/ only, which is a hole: most of these
    # operations are actually reached from Private/engine, not from a cmdlet a
    # person runs.
    #
    # The rule there is NOT "every file pins". The pin is process-wide and is
    # taken ONCE, by the engine, before it dispatches - so a helper called
    # underneath it inherits the pin, and adding a second one would nest a
    # context switch for no reason. GuestOps.ps1 is exactly that case.
    #
    # So what is held here is the shape that makes the pin sufficient: the set
    # of private files that reach Azure by group and name is SMALL and NAMED,
    # and the one entry point they all sit under really does pin and put it
    # back. A new file joining that set fails this, which is the moment to
    # decide whether it is under the pin or needs its own.

    BeforeAll {
        $script:privateCallers = @{}
        foreach ($file in Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private') -Filter '*.ps1' -Recurse) {
            if ($file.FullName -like '*azureops*') { continue }
            $code = Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $file.FullName -Raw)
            $hits = @($script:ambientOps | Where-Object { $code -match "\b$([regex]::Escape($_))\b" })
            if ($hits.Count) { $script:privateCallers[$file.Name] = $hits }
        }
    }

    It 'only these private files reach Azure by group and name' {
        # StateMachine.ps1 - takes the pin itself, before it dispatches.
        # GuestOps.ps1    - runs only under StateMachine, so it inherits it.
        # SafetyAllDisks.ps1 - the safety-copy and rollback steps' helpers,
        #                   called only from StateMachine's steps (SAFETY-ALL-1).
        # RestoreAll.ps1  - Restore this machine's data disks (RESTORE-ALL-1),
        #                   called only from Restore-VmfVm, which pins (below).
        # RestoreDiskResume.ps1 - REBUILD-REMOVE-RECOVER-1: the restore's resume
        #                   delete (Remove-VmfDiskForResume, only from Restore-VmfVm)
        #                   and the failed-definition delete (only from
        #                   ReservationPutBack.ps1, under StateMachine), each under a pin.
        # KernelUpdateStep.ps1 - the kernel update inside GUEST_PREP and its
        #                   rollback (MANA-LINUX-KERNEL-1), called only from
        #                   StateMachine, which pins (next test).
        # InstantAccessCopies.ps1 - SAFETY-ULTRA-1's wait for the Premium SSD v2
        #                   and Ultra Disk copies reads the power state by group
        #                   and name; called only from StateMachine (next tests).
        # DiskEncryption.ps1 - SAFETY-CMK-1's New-VmfOsDiskFromCopy makes an OS
        #                   disk from a copy by group and name; called only
        #                   under a pin (the test after next).
        # ReservationPutBack.ps1 - ROLLBACK-CRG-1's leave, join and rebuild in the
        #                   machine's capacity reservation group, by group and name;
        #                   called only under a pin (the test after it).
        # RollbackDisksBeforeMove.ps1 - ROLLBACK-DISKS-FIRST-1's New-VmfRollbackDisksBeforeMove makes the
        #                   rollback disks by group and name and starts the
        #                   machine after a refusal; called only from StateMachine,
        #                   which pins (the test after next). Its readers and its
        #                   cleanup act by resource id and need no pin.
        # SwapPending.ps1 - SWAP-REFUSED-AFTER-STOP-1's Invoke-VmfDataDiskSwap
        #                   swaps data disks by group and name; called only under
        #                   a pin (the next test).
        # MadeDisks.ps1  - MADE-DISK-RECORD-1's Get-VmfMachineAbsentReason asks by
        #                   group and name whether the machine exists, and takes
        #                   its own pin first (the test after next).
        # EmptyLun.ps1   - RESTORE-EMPTY-LUN-1's Invoke-VmfEmptyLunAttach attaches a
        #                   disk to an empty LUN by group and name; called only under
        #                   a pin (the test after it).
        # WorkloadCheck.ps1 - CLUSTER-NOT-RUNNING-1's start, wait and stop of a
        #                   machine for the cluster check, by group and name;
        #                   called only from StateMachine's PRECHECK (the next test).
        # RollbackEmptyLun.ps1 - ROLLBACK-EMPTY-LUN-1's read of the data disk LUNs
        #                   and its fill of an empty LUN (Resolve-VmfEmptyDataLun),
        #                   by group and name; called only from StateMachine's
        #                   rollback, which runs under the engine pin (below).
        # PrecheckExtensions.ps1 - PRECHECK-EXT-READ-1's read of the extensions by
        #                   group and name; called only from StateMachine's
        #                   PRECHECK, which runs under the engine pin.
        # PreviewFeatureGate.ps1 - PREVIEW-PUTBACK-1's Get-VmfPreviewPutBackCheck
        #                   reads the size of the machine by group and name;
        #                   called only from StateMachine's rollback and from
        #                   Restore-VmfVm, each under a pin.
        # RestoreOriginalBack.ps1 - RESTORE-ORIGINAL-DELETE-RESTART-1's way back:
        #                   puts the original OS disk back, starts the machine and
        #                   deletes the temporary disks, by group and name; called
        #                   only from Restore-VmfVm, which pins (the tests below).
        # VolumesAfterPutBack.ps1 - VOLUMES-ONLINE-1's check inside the machine
        #                   after a put-back reads the power state and waits for
        #                   the agent by group and name; called only from
        #                   StateMachine's rollback and from Restore-VmfVm, each
        #                   under a pin.
        # RestorePermissions.ps1 - RESTORE-PERM-CHECK-1's read of the machine as
        #                   it is now, by group and name, for the permission check
        #                   of a restore; called only from Restore-VmfVm, which pins
        #                   (the test after it).
        # RollbackStart.ps1 - ROLLBACK-CAPACITY-1's start at the end of a rollback,
        #                   tried again on an allocation failure, by group and name;
        #                   called only from StateMachine's rollback, under the
        #                   engine pin (the next test).
        $allowed = @('RollbackStart.ps1', 'RestorePermissions.ps1', 'VolumesAfterPutBack.ps1', 'RestoreOriginalBack.ps1', 'PrecheckExtensions.ps1', 'StateMachine.ps1', 'GuestOps.ps1', 'SafetyAllDisks.ps1', 'RestoreAll.ps1', 'RestoreDiskResume.ps1', 'KernelUpdateStep.ps1', 'InstantAccessCopies.ps1', 'DiskEncryption.ps1', 'RollbackDisksBeforeMove.ps1', 'ReservationPutBack.ps1', 'SwapPending.ps1', 'MadeDisks.ps1', 'EmptyLun.ps1', 'WorkloadCheck.ps1', 'RollbackEmptyLun.ps1', 'PreviewFeatureGate.ps1')
        $unexpected = @($script:privateCallers.Keys | Where-Object { $_ -notin $allowed })
        $unexpected -join ', ' | Should -BeNullOrEmpty -Because 'a new private caller must be shown to run under the engine pin, or take its own'
    }

    It 'ROLLBACK-CAPACITY-1: the rollback start with its tries runs only under the engine''s subscription pin' {
        # StateMachine pins before it dispatches a step or a rollback, the only caller.
        $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
            Where-Object { $_.Name -ne 'RollbackStart.ps1' } |
            Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match '\bStart-VmfRollbackVm\b' } |
            ForEach-Object Name | Sort-Object)
        $callers | Should -Be @('StateMachine.ps1')
    }

    It 'PREVIEW-PUTBACK-1: the check before the way back of a Preview move reads the machine only under a subscription pin' {
        # StateMachine pins before it dispatches a rollback; Restore-VmfVm pins
        # (the Describe above) before it asks.
        $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
            Where-Object { $_.Name -ne 'PreviewFeatureGate.ps1' } |
            Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match '\bGet-VmfPreviewPutBackCheck\b' } |
            ForEach-Object Name | Sort-Object)
        $callers | Should -Be @('Restore-VmfVm.ps1', 'StateMachine.ps1')
    }

    It 'RESTORE-PERM-CHECK-1: the permission check of a restore reads the machine only under a subscription pin' {
        # Restore-VmfVm pins (the Describe above) before it asks.
        $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
            Where-Object { $_.Name -ne 'RestorePermissions.ps1' } |
            Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match '\bGet-VmfRestorePermissionStop\b' } |
            ForEach-Object Name | Sort-Object)
        $callers | Should -Be @('Restore-VmfVm.ps1')
    }

    # REBUILD-REMOVE-ROLE-1: the patch settings after a rebuild (Invoke-VmfRebuildPatchSettings) are gone.

    It 'PRECHECK-EXT-READ-1: the extensions are read by group and name only under the engine''s subscription pin' {
        # StateMachine pins before it dispatches PRECHECK, the only caller.
        $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
            Where-Object { $_.Name -ne 'PrecheckExtensions.ps1' } |
            Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match '\bRead-VmfPrecheckExtensions\b' } |
            ForEach-Object Name | Sort-Object)
        $callers | Should -Be @('StateMachine.ps1')
    }

    It 'CLUSTER-NOT-RUNNING-1: the cluster check starts and stops a machine only under the engine''s subscription pin' {
        # StateMachine pins before it dispatches PRECHECK, the only caller.
        $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
            Where-Object { $_.Name -ne 'WorkloadCheck.ps1' } |
            Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match '\b(Get-VmfWorkloadCheckStop|Restore-VmfClusterCheckPower)\b' } |
            ForEach-Object Name | Sort-Object)
        # VOLUMES-RETRY-CHECK-OFF-1: the check of the volumes starts and returns
        # a machine the same way (Invoke-VmfVolumesCheckStarted, below), and
        # Invoke-VmfVolumesCheck, which pins itself, returns one an earlier
        # job started (VOLUMES-CHECK-JOB-STOP-1).
        $callers | Should -Be @('Invoke-VmfVolumesCheck.ps1', 'StateMachine.ps1', 'VolumesAfterPutBack.ps1')
    }

    It 'VOLUMES-RETRY-CHECK-OFF-1: the check of the volumes starts and stops a machine only under a subscription pin' {
        # Invoke-VmfVolumesCheckBeforeRetry runs only in PRECHECK, which
        # StateMachine pins; Invoke-VmfVolumesCheck pins itself.
        $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
            Where-Object { $_.Name -ne 'VolumesAfterPutBack.ps1' } |
            Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match '\b(Invoke-VmfVolumesCheckStarted|Invoke-VmfVolumesCheckBeforeRetry)\b' } |
            ForEach-Object Name | Sort-Object)
        $callers | Should -Be @('Invoke-VmfVolumesCheck.ps1', 'StateMachine.ps1')
        $own = Get-VmfCodeOnly -Language PowerShell -Text (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Invoke-VmfVolumesCheck.ps1') -Raw)
        $own.IndexOf('Use-VmfSubscriptionContext') | Should -BeGreaterThan -1
        $own.IndexOf('Use-VmfSubscriptionContext') | Should -BeLessThan $own.IndexOf('Invoke-VmfVolumesCheckStarted')
    }

    It 'SWAP-REFUSED-AFTER-STOP-1: a data-disk swap that is tried again runs only under a subscription pin' {
        # StateMachine pins; RestoreAll.ps1 runs only under Restore-VmfVm, and
        # Complete-VmfDataDiskSwap pins itself (the Describe above holds both).
        $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
            Where-Object { $_.Name -ne 'SwapPending.ps1' } |
            Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match '\bInvoke-VmfDataDiskSwap\b' } |
            ForEach-Object Name | Sort-Object)
        $callers | Should -Be @('Complete-VmfDataDiskSwap.ps1', 'RestoreAll.ps1', 'StateMachine.ps1')
    }

    It 'RESTORE-EMPTY-LUN-1: a disk goes on an empty LUN only under a subscription pin' {
        # Complete-VmfDataDiskSwap pins itself; RestoreAll.ps1 runs only under
        # Restore-VmfVm, which pins (the Describe above holds both).
        foreach ($fn in 'Invoke-VmfEmptyLunAttach', 'Resolve-VmfEmptyDataLun') {
            $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
                Where-Object { $_.Name -ne 'EmptyLun.ps1' } |
                Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match "\b$fn\b" } |
                ForEach-Object Name | Sort-Object)
            foreach ($c in $callers) { $c | Should -BeIn @('Complete-VmfDataDiskSwap.ps1', 'RestoreAll.ps1', 'RollbackEmptyLun.ps1') -Because "$fn acts by resource group and name" }
            $callers.Count | Should -BeGreaterThan 0
        }
    }

    It 'ROLLBACK-EMPTY-LUN-1: the rollback reads and fills its data disk LUNs only under the engine''s subscription pin' {
        # StateMachine pins before it dispatches a step or a rollback, the only caller.
        $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
            Where-Object { $_.Name -ne 'RollbackEmptyLun.ps1' } |
            Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match '\b(Get-VmfRollbackLiveLuns|Resolve-VmfRollbackSwapLuns)\b' } |
            ForEach-Object Name | Sort-Object)
        $callers | Should -Be @('StateMachine.ps1')
    }

    It 'MADE-DISK-RECORD-1: the cleanup asks whether a machine exists only under the machine''s own subscription pin' {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'MadeDisks.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $args[0].Name -eq 'Get-VmfMachineAbsentReason' }, $true) | Select-Object -First 1
        $code = Get-VmfCodeOnly -Language PowerShell -Text $fn.Extent.Text
        $pin = $code.IndexOf('Use-VmfSubscriptionContext -SubscriptionId $sub')
        $pin | Should -BeGreaterThan 0
        $code.IndexOf('Test-VmfVmExists') | Should -BeGreaterThan $pin
        $code | Should -Match 'finally \{ Restore-VmfSubscriptionContext'
        # And Test-VmfVmExists is asked nowhere else in MadeDisks.ps1.
        ([regex]::Matches((Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'MadeDisks.ps1')), '\bTest-VmfVmExists\b')).Count | Should -Be 1
    }
    It 'ROLLBACK-CRG-1: the capacity reservation group of a rollback or a restore changes only under a subscription pin' {
        # StateMachine pins; Restore-VmfVm pins (the Describe above).
        # REBUILD-REMOVE-ENGINE-1: Invoke-VmfRebuildInReservationGroup is gone.
        foreach ($fn in 'Get-VmfReservationPutBack', 'Invoke-VmfReservationLeave', 'Invoke-VmfReservationRejoin') {
            $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
                Where-Object { $_.Name -ne 'ReservationPutBack.ps1' } |
                Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match "\b$fn\b" } |
                ForEach-Object Name | Sort-Object)
            foreach ($c in $callers) { $c | Should -BeIn @('StateMachine.ps1', 'Restore-VmfVm.ps1') -Because "$fn acts by resource group and name" }
            $callers.Count | Should -BeGreaterThan 0
        }
    }
    It 'the SAFETY-ULTRA-1 wait and the check before the move run only under StateMachine' {
        foreach ($fn in 'Wait-VmfInstantAccessCopies', 'Test-VmfCopyWindowBeforeConversion') {
            $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
                Where-Object { $_.Name -ne 'InstantAccessCopies.ps1' } |
                Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match "\b$fn\b" } |
                ForEach-Object Name)
            $callers | Should -Be @('StateMachine.ps1') -Because "$fn acts by resource group and name, so it must run under the engine's subscription pin"
        }
    }

    It 'SAFETY-CMK-1: an OS disk is made from a copy only under a subscription pin' {
        # StateMachine pins; Restore-VmfVm and Restore-VmfVmShell pin (the
        # Describe above); RestoreRebuild.ps1 runs only under Restore-VmfVm.
        $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
            Where-Object { $_.Name -ne 'DiskEncryption.ps1' } |
            Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match '\bNew-VmfOsDiskFromCopy\b' } |
            ForEach-Object Name | Sort-Object)
        # ROLLBACK-DISKS-FIRST-1: RollbackDisksBeforeMove.ps1 makes the disks for the way
        # back with it, and runs only under StateMachine (next test).
        # REBUILD-REMOVE-RECOVER-1: RecoverAllDisks.ps1 and RestoreRebuild.ps1 are gone.
        $callers | Should -Be @('Restore-VmfVm.ps1', 'RollbackDisksBeforeMove.ps1', 'StateMachine.ps1')
    }

    It 'ROLLBACK-DISKS-FIRST-1: the rollback disks are made only under StateMachine''s pin' {
        $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
            Where-Object { $_.Name -ne 'RollbackDisksBeforeMove.ps1' } |
            Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match '\bNew-VmfRollbackDisksBeforeMove\b' } |
            ForEach-Object Name)
        $callers | Should -Be @('StateMachine.ps1') -Because 'New-VmfRollbackDisksBeforeMove acts by resource group and name, so it must run under the engine''s subscription pin'
    }

    It 'KernelUpdateStep.ps1 runs only under StateMachine (MANA-LINUX-KERNEL-1)' {
        # PREP-ROLLBACK-1: Invoke-VmfPutBackAfterStop is gone - the put-back
        # goes through the engine's own rollback checkpoint in StateMachine.
        foreach ($fn in 'Invoke-VmfKernelUpdateStep', 'Resume-VmfKernelUpdateReading') {
            $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
                Where-Object { $_.Name -ne 'KernelUpdateStep.ps1' } |
                Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match "\b$fn\b" } |
                ForEach-Object Name)
            $callers | Should -Be @('StateMachine.ps1') -Because "$fn acts by resource group and name, so it must run under the engine's subscription pin"
        }
    }

    It 'RestoreDiskResume.ps1 runs only under a pin: <fn> from <want>' -ForEach @(
        # RESTORE-ORIGINAL-DELETE-RESTART-1: RestoreOriginalBack.ps1 runs only
        # under Restore-VmfVm (the test after this one).
        @{ fn = 'Remove-VmfDiskForResume'; want = @('Restore-VmfVm.ps1', 'RestoreOriginalBack.ps1') }) {
        # REBUILD-REMOVE-RECOVER-1: the helper left of RestoreRebuild.ps1 (and
        # REBUILD-REMOVE-ENGINE-1 deleted Remove-VmfFailedDefinition). Restore-VmfVm pins.
        $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
            Where-Object { $_.Name -ne 'RestoreDiskResume.ps1' } |
            Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match "\b$fn\b" } |
            ForEach-Object Name | Sort-Object)
        $callers | Should -Be @($want)
    }
    It 'RESTORE-ORIGINAL-DELETE-RESTART-1: the way back after a refused delete runs only under Restore-VmfVm, which pins' {
        $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
            Where-Object { $_.Name -ne 'RestoreOriginalBack.ps1' } |
            Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match '\bInvoke-VmfRestoreOriginalBack\b' } |
            ForEach-Object Name)
        $callers | Should -Be @('Restore-VmfVm.ps1')
    }
    It 'RestoreAll.ps1 runs only under Restore-VmfVm, and Restore-VmfVm pins the machine''s subscription' {
        $callers = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse |
            Where-Object { $_.Name -ne 'RestoreAll.ps1' } |
            # RESTORE-END-JOB-1: the restore and its rebuild call it through
            # Invoke-VmfResumableDataRestore, in RestoreAll.ps1, so both are asked.
            Where-Object { (Get-VmfCodeOnly -Language PowerShell -Text (Get-Content $_.FullName -Raw)) -match '\b(Invoke-VmfOperatorDataRestore|Invoke-VmfResumableDataRestore)\b' } |
            ForEach-Object Name)
        $callers | Should -Be @('Restore-VmfVm.ps1')
        $restore = Get-VmfCodeOnly -Language PowerShell -Text (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Restore-VmfVm.ps1') -Raw)
        $restore | Should -Match 'Use-VmfSubscriptionContext -SubscriptionId'
    }
    It 'and this test is really finding them, rather than finding nothing' {
        # A derived check that derives nothing passes everything.
        $script:privateCallers.Keys | Should -Contain 'StateMachine.ps1'
        @($script:privateCallers['StateMachine.ps1']).Count | Should -BeGreaterThan 5
    }

    It 'the engine pins the subscription before it dispatches, and puts it back' {
        $engine = Get-VmfCodeOnly -Language PowerShell -Text (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw)
        $engine | Should -Match 'Use-VmfSubscriptionContext -SubscriptionId \$ctx\.SubscriptionId'
        $engine | Should -Match 'Restore-VmfSubscriptionContext'
        # The pin must come BEFORE the handlers that use it, or it pins nothing.
        $engine.IndexOf('Use-VmfSubscriptionContext') |
            Should -BeLessThan $engine.IndexOf('$handlers = @{') -Because 'a pin taken after dispatch pins nothing'
    }

    It 'and a subscription it cannot reach parks the machine rather than guessing' {
        # Proceeding without the pin would address the machine against whatever
        # the process was last pointed at - the defect this whole rule exists
        # for, arriving silently.
        $engine = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        $engine | Should -Match "ReasonCode 'subscriptionNotReachable'"
        $engine | Should -Match "NewState 'NEEDS_DECISION'"
    }
}

Describe 'SEC-1 / F10: the snapshot operations act on the id itself' {

    BeforeAll {
        $script:vmOps = Get-Content (Join-Path $script:opsDir 'AzureOpsVm.ps1') -Raw
    }

    It 'deleting and reading a safety copy go through ARM by resource id' {
        # These two are reached from inside the service, so they may not pin a
        # process-wide context. They used to split the id to group and name
        # and call Remove-AzSnapshot / Get-AzSnapshot, which resolve that pair
        # against whatever subscription the process was pointed at - and a
        # delete that found nothing was reported as success, which then marked
        # the safety copies gone and refused every later restore.
        foreach ($fn in Get-VmfFunctionAst (Join-Path $script:opsDir 'AzureOpsVm.ps1')) {
            if ($fn.Name -notin 'Remove-VmfSnapshot', 'Test-VmfSnapshotExists') { continue }
            # Scan the CODE. The comment beside the fix names the call it
            # replaced, and an assertion that matched that would pass only
            # while somebody was still explaining the defect.
            $body = Get-VmfCodeOnly -Language PowerShell -Text $fn.Extent.Text
            # PERF-TELEMETRY-1: Invoke-VmfArmRequest is Invoke-AzRestMethod,
            # timed - the same call on the same path.
            $body | Should -Match 'Invoke-AzRestMethod|Invoke-VmfArmRequest -Method \w+ -Path' -Because "$($fn.Name) must address the snapshot by its id"
            $body | Should -Match 'Assert-VmfResourceId' -Because "$($fn.Name) must refuse an id with no subscription"
            $body | Should -Not -Match 'Remove-AzSnapshot|Get-AzSnapshot' -Because "$($fn.Name) must not resolve by group and name"
        }
    }

    It 'an id without a subscription is refused, not guessed at' {
        InModuleScope VmMigrationFactory {
            $good = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg/providers/Microsoft.Compute/snapshots/s1'
            Assert-VmfResourceId -ResourceId $good | Should -Be '11111111-2222-3333-4444-555555555555'
            foreach ($bad in @(
                '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/s1',
                '/resourceGroups/rg/providers/Microsoft.Compute/snapshots/s1',
                'rg/s1',
                '')) {
                { Assert-VmfResourceId -ResourceId $bad } | Should -Throw -Because "'$bad' names no subscription"
            }
        }
    }
}
