#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RETRY-1: a retry button is only worth pressing if the machine says what
# stopped it and what to do about it.
#
# The failure mode this guards against is a NEW stop site shipping with no
# guidance behind it. That is not hypothetical: every stop in this engine was
# free text until now, and the dashboard could only show engine sentences to an
# operator who had to guess what they meant.
#
# So both sides are derived from source and compared - the same guard that
# caught the stale guest sample and the capture field that only ever existed in
# a test fixture. Add a stop without a code, or a code without guidance, and
# this fails before it reaches a customer.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:dataFile = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json'
    $script:table = Get-Content $script:dataFile -Raw -Encoding utf8 | ConvertFrom-Json
    $script:codes = @($script:table.reasons | ForEach-Object { $_.code })

    $script:smFile = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1'
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:sm = Get-Content $script:smFile -Raw
    $script:stopFile = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StopReasons.ps1'
    $script:stopSrc = Get-Content $script:stopFile -Raw
    $script:dash = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))

    # Codes the ENGINE actually emits: Reason = '...' in a handler result, and
    # -ReasonCode '...' on a transition. Classifier codes come from the
    # patterns table in StopReasons.ps1.
    # OLD-SKU-1C: the disk type checks live in their own engine file. Named
    # here, not every engine file: other files use Reason for other things.
    $script:engineSrc = $script:sm + "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'DiskType.ps1'))
    # REBUILD-REMOVE-RECOVER-1: RestoreRebuild.ps1, which stopped a restore that
    # could not rebuild the machine (restoreRebuildFailed), is gone.
    # ROLLBACK-RETRY-CAPTURE-2: PRECHECK's check of the original size is here.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'OriginalCapture.ps1'))
    # SAFETY-ULTRA-1: the Premium SSD v2 and Ultra Disk copy checks (PRECHECK,
    # SAFETY_PRISTINE, the start of CONVERTING) stop the machine from here.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'InstantAccessCopies.ps1'))
    # SAFETY-CMK-1: PRECHECK's read of each disk's encryption stops the machine from here.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'DiskEncryption.ps1'))
    # ROLLBACK-DISKS-FIRST-1: the rollback disks, made at the end of SAFETY_PRISTINE, stop the machine from here.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'RollbackDisksBeforeMove.ps1'))
    # AN-ONE-NIC-1: PRECHECK's check of accelerated networking on the target size.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'TargetAnFit.ps1'))
    # TEMP-DISK-PREVIEW-1: PRECHECK's read of the preview feature stops the machine from here.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'PreviewFeatureGate.ps1'))
    # IDENTITY-LOSS-1's IdentityLossGate.ps1 is gone (REBUILD-REMOVE-ROLE-1).
    # CLUSTER-DETECT-1: PRECHECK's check inside the machine for a cluster node.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'WorkloadCheck.ps1'))
    # UAMI-ASSIGN-1: PRECHECK's check that this account may assign each user-assigned identity.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'IdentityAssign.ps1'))
    # NIC-JOIN-SCOPE-1: PRECHECK's check that this account may join each network interface, at its own scope.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'NicJoinScope.ps1'))
    # CRG-MOVE-1: PRECHECK's check that the machine's own capacity reservation group reserves the target size.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'ReservationMove.ps1'))
    # BATCH-CYCLECLOUD-SIGNAL-1: PRECHECK's check for a node of an Azure CycleCloud cluster.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'CycleCloudCheck.ps1'))
    # EOL-RELEASE-AN-1: Checking's stop for a Linux release past its vendor's end of standard support.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'ReleaseEndOfLifeCheck.ps1'))
    # REBUILD-MOVE-HOST-1: PRECHECK's check for a machine on a dedicated host or with hibernation enabled.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'HostHibernationCheck.ps1'))
    # PRECHECK-EXT-READ-1: PRECHECK's read of the extensions, and its stop when Azure does not return them.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'PrecheckExtensions.ps1'))
    # DISK-TYPE-DEALLOCATED-1: PRECHECK's stop for a disk with no type.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'DiskTypeKnown.ps1'))
    # STOP-TEXT-SPECIFIC-1: the put-back permission check on a capacity
    # reservation group, and the lock verdict, name their own reasons.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'ReservationPutBack.ps1'))
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'validate' 'ResourceLocks.ps1'))
    # RHEL-PINNED-KERNEL-ADVICE-1: GUEST_PREP's kernel update stops the machine from here.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'KernelUpdateStep.ps1'))
    # TARGET-CAPABILITY-PRECHECK-1: Checking's stop for a target size that does not support a feature the machine uses.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'TargetFeatureGate.ps1'))
    # VOLUMES-NOT-CHECKED-WORDS-1: Check the volumes (VOLUMES-RESTORE-MIGRATED-1) records volumesNotChecked from here.
    $script:engineSrc += "`n" + (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Invoke-VmfVolumesCheck.ps1'))
    $script:usedCodes = @(
        @([regex]::Matches($script:engineSrc, "Reason\s*=\s*'([a-zA-Z]+)'") | ForEach-Object { $_.Groups[1].Value })
        @([regex]::Matches($script:engineSrc, "-ReasonCode\s+'([a-zA-Z]+)'") | ForEach-Object { $_.Groups[1].Value })
        @(& {
            # The stop-code decision is a multi-line if/elseif/else. Take the
            # whole assignment and read every quoted code out of it, so the
            # shape of that conditional can change without silently dropping a
            # code out of this comparison - which is exactly what happened when
            # FAIL-1 turned a one-line ternary into a four-way choice.
            $block = [regex]::Match($script:sm, "(?s)\`$stopCode =.*?\r?\n\s*\r?\n").Value
            # The conditions name STATES ('STARTING', 'VALIDATING'); the
            # branches name CODES. Codes are camelCase, states are upper-case,
            # so drop anything with no lower-case letter rather than listing
            # the state names here and having to maintain that list too.
            [regex]::Matches($block, "'([a-zA-Z]+)'") | ForEach-Object { $_.Groups[1].Value } |
                Where-Object { $_ -cmatch '[a-z]' }
        })
        @([regex]::Matches($script:stopSrc, "^\s{8}([a-zA-Z]+)\s*=\s*@\(", 'Multiline') | ForEach-Object { $_.Groups[1].Value })
        'stepFailedRepeatedly'
    ) | Sort-Object -Unique
}

Describe 'RETRY-1: the guidance table is well formed' {
    It 'loads through the module, not just off disk' {
        InModuleScope VmMigrationFactory { @((Get-VmfStopReasons).reasons).Count } | Should -BeGreaterThan 10
    }

    It 'an unknown code resolves to nothing, never to a guess' {
        InModuleScope VmMigrationFactory { Get-VmfStopGuidance -Code 'noSuchCode' } | Should -BeNullOrEmpty
        InModuleScope VmMigrationFactory { Get-VmfStopGuidance -Code '' } | Should -BeNullOrEmpty
        InModuleScope VmMigrationFactory { (Get-VmfStopGuidance -Code 'capacityUnavailable').retry } |
            Should -Be 'whenAvailable'
    }

    It 'every reason states what happened, what it means and what to do' {
        $bad = @(foreach ($r in $script:table.reasons) {
            foreach ($f in 'code', 'title', 'meaning', 'whatToDo') {
                if ([string]::IsNullOrWhiteSpace($r.$f)) { "$($r.code): $f is empty" }
            }
        })
        $bad -join '; ' | Should -BeNullOrEmpty
    }

    It 'every reason says where it left the machine, and whether retrying helps' {
        foreach ($r in $script:table.reasons) {
            $r.machine | Should -BeIn @('untouched', 'restored', 'changed') `
                -Because "$($r.code) must state where the machine was left"
            $r.retry | Should -BeIn @('afterFix', 'whenAvailable', 'unlikely', 'notSupported', 'outOfScope', 'decision') `
                -Because "$($r.code) must say honestly whether a retry helps"
        }
    }

    It 'only a stop that cannot put the machine back says it is NOT as it was' {
        # This began as a boolean `touched` that conflated "was it changed"
        # with "is it back", and the page printed the reassuring half - a
        # machine held after a failed health check read as "put back as it
        # was". FAIL-1 then made that literally true for every case except
        # one, so the guard inverts: only a code where putting the machine
        # back is not guaranteed may claim `changed`, and the list is
        # explicit so a new one is a decision rather than a slip.
        #
        # EVAL-M4 added the second member. rollbackFailed is the case where
        # the rollback ran and failed; stepLoopLimit is the case where the
        # machine was stopped mid-flight because the steps never settled, so
        # no rollback was ever reached. Both leave a machine that may not be
        # as it was, and both record a per-stop machineState that overrides
        # this default - which is why widening the list costs nothing on a
        # real document and still refuses a careless third.
        #
        # RESTORE-PB-1 added the third, as a decision: a person's restore that
        # deleted the machine's definition to rebuild it, where Azure refused
        # both the rebuild and the way back. The machine has no definition.
        # SWAP-REFUSED-AFTER-STOP-1 added the fourth, as a decision: Azure did
        # not swap every data disk back, so the machine is stopped with disks
        # from two moments until Finish the rollback swaps the rest.
        # PREVIEW-PUTBACK-1 added the fifth, as a decision: the rollback of an
        # in-place upgrade (Preview) did not start, because the preview feature
        # is not registered, so the machine stays as the failed step left it.
        # POWER-ONLY-CHANGED-1 added the sixth, as a decision: a retry whose
        # first step, the put-back of the power state Checking found, Azure
        # refused at each try. The machine can be running when it was found
        # deallocated or stopped.
        # REBUILD-REMOVE-RECOVER-1: restoreRebuildFailed went with the restore that rebuilt.
        # OLD-VERSION-READERS-REMOVE-1: oldRebuildNotResumed went with the reader of an earlier version's rebuild.
        # VOLUMES-ONLINE-1 added the seventh: a rollback or a restore put the
        # disks back, and a volume mounted before the move is not mounted now.
        # ROLLBACK-CAPACITY-1 added the eighth, as a decision: Azure refused the
        # original size, so the rollback stopped with the machine on its new size.
        # VOLUMES-NOT-CHECKED-WORDS-1 added the ninth: the check of the volumes
        # that a retry or Check the volumes runs could not run, so nothing says
        # the volumes are back - the machine stays as the stop before it left it.
        @($script:table.reasons | Where-Object machine -eq 'changed' | ForEach-Object { $_.code } | Sort-Object) |
            Should -Be @('dataDiskSwapRefused', 'powerNotPutBack', 'previewRollbackNotRegistered', 'rollbackFailed', 'rollbackSizeRefused', 'stepLoopLimit', 'volumesNotBack', 'volumesNotChecked')
    }

    It 'the post-conversion failures say the machine was put back' {
        # FAIL-1 removed the hold, so these are no longer left on new hardware.
        # A stale reassurance in the other direction would be just as wrong.
        foreach ($c in 'bootFailedAfterConversion', 'validationFailedAfterConversion', 'rolledBack') {
            $r = @($script:table.reasons | Where-Object code -eq $c)[0]
            $r.machine | Should -Be 'restored' -Because "$c always rolls back now"
            # 'rolled the machine back' is the STE form: name the thing rather
            # than point at it with a pronoun.
            $r.meaning | Should -Match 'rolled (it |the machine )?back'
        }
    }

    It 'codes are unique' {
        ($script:codes | Sort-Object -Unique).Count | Should -Be $script:codes.Count
    }

    It 'DECIDE-1: a stop that is a CHOICE is not filed as a fault' {
        # The four original kinds all describe a fault: something to correct,
        # something to wait for, something retrying cannot help, something this
        # engine cannot do. None of them is "nothing is wrong and a person must
        # choose", so the one stop that is purely a choice was tagged afterFix.
        #
        # The cost was not the label. RETRY-1's own question is "realistically,
        # what could a customer fix before hitting retry?" - and for this reason
        # the honest answer is NOTHING. A rebuild destroys a system-assigned
        # identity; that is what a rebuild is. The product told the operator to
        # correct it and offered a retry that re-ran the same check against the
        # same setting and stopped again, for ever.
        # REBUILD-REMOVE-ACCEPT-1: that stop is gone with the rebuild. The
        # choice left with no correction is accelerated networking that the
        # target requires: nothing on the machine can be corrected, and only a
        # person accepts turning it on.
        $r = @($script:table.reasons | Where-Object code -eq 'acceleratedNetworkingRequired')[0]
        $r.retry | Should -Be 'decision' -Because 'no correction exists, so afterFix was a lie'
    }

    It 'and a decision never tells anyone to correct something or to try again' {
        # The mirror of the notSupported check above. An internal contradiction
        # the dashboard and the manual would both render faithfully.
        $decisions = @($script:table.reasons | Where-Object { $_.retry -eq 'decision' })
        $decisions.Count | Should -BeGreaterThan 0 -Because 'an empty rule proves nothing'
        foreach ($r in $decisions) {
            $r.whatToDo | Should -Not -Match '(?i)try (it|the machine|this machine) again'
            $r.whatToDo | Should -Not -Match '(?i)^correct |(?i)[.] correct '
        }
    }

    It 'and every choice names the lever that carries it, and who may pull it' {
        # CONTRACT. The reason, the plan lever and the role all had to agree,
        # and before this they agreed nowhere - the lever existed in the engine,
        # the API accepted it, and the dashboard never sent it, so the choice
        # was reachable from a command line and not from the product.
        $levers = @('safetyCopy', 'capacityGate', 'requireApproval', 'onDDataFound',
                    'onDriverBelowFloor', 'acceleratedNetworking', 'onSriovUnmanagedMissing',
                    'keepSnapshotDays', 'throttle', 'targetGeneration', 'onReleaseEndOfLife')
                    # REBUILD-REMOVE-ACCEPT-1: onSystemAssignedIdentity and rebuild
                    # are gone with the rebuild; no choice may name them.
        # A `decision` reason MUST carry one - it has nothing else to offer.
        foreach ($r in @($script:table.reasons | Where-Object { $_.retry -eq 'decision' })) {
            $r.decide | Should -Not -BeNullOrEmpty -Because "$($r.code) has no correction, so it must name a choice"
        }
        foreach ($r in @($script:table.reasons | Where-Object { $_.PSObject.Properties['decide'] })) {
            $r.decide.lever | Should -BeIn $levers -Because "$($r.code) must name a lever the engine has"
            [string]$r.decide.accept | Should -Not -BeNullOrEmpty
            $r.decide.approver | Should -BeTrue -Because 'accepting permanent loss is a risk acceptance, not an operational retry'
        }
    }

    It 'DECIDE-2: a choice may sit BESIDE a correction' {
        # DECIDE-1 tied the decide block to the retry kind and asserted here
        # that no other reason could carry one. That was too tight:
        # dataOnTempDrive and driverBelowFloor can be fixed, so they must
        # offer the fix as well.
        #
        # All three of the wave's "stop and ask" gates carry a choice. Two of
        # them ALSO have a real correction - move the files off the temporary
        # disk, patch the kernel - so they keep retry `afterFix`, because
        # correcting is usually the better answer and the retry genuinely
        # works. What they lacked was any way to say "yes, accept it" for ONE
        # machine: the only yes was the wave-wide setting.
        $withChoice = @($script:table.reasons | Where-Object { $_.PSObject.Properties['decide'] } |
            ForEach-Object { $_.code } | Sort-Object)
        # GEN-V5-1 added the fourth: Intel D v5 requires accelerated networking, and
        # an approver can accept turning it on for one machine.
        # REBUILD-ACCEPT-1 added the fifth: an approver accepts the rebuild of one machine.
        # REBUILD-REMOVE-ACCEPT-1 took the rebuild and the identity choices away
        # with the rebuild: no move rebuilds a machine.
        # AN-PROCEED-NETVSC-1 (2026-11-06: a move whose network cannot work on
        # accelerated networking is not allowed) took driverBelowFloor's choice away:
        # with no MANA driver there is nothing to accept, only to correct.
        # EOL-RELEASE-AN-1 (2026-11-14) added linuxReleaseEndOfLife: an
        # approver accepts a Linux release past its vendor's end of standard support.
        # VF-UNMANAGED-CONFIG-1 added two that share one setting: the network
        # settings do not set the SR-IOV interface as unmanaged, or the check
        # gave no answer. Both can be corrected, and both can be accepted.
        $withChoice | Should -Be @('acceleratedNetworkingRequired', 'dataOnTempDrive', 'linuxReleaseEndOfLife', 'sriovNotUnmanaged', 'sriovUnmanagedNotChecked')
    }

    It 'and the two that have a correction KEEP their retry, which still works' {
        # Moving these to `decision` would withdraw the retry, and the retry is
        # the better answer for both - a customer who moves the files or
        # patches the kernel loses nothing at all.
        $floor = @($script:table.reasons | Where-Object code -eq 'driverBelowFloor')[0]
        $floor.retry | Should -Be 'afterFix'
        $floor.whatToDo | Should -Match '(?i)^Choose Update the kernel'
        $floor.whatToDo | Should -Not -Match '(?i)approver'
        foreach ($c in 'dataOnTempDrive') {
            $r = @($script:table.reasons | Where-Object code -eq $c)[0]
            $r.retry | Should -Be 'afterFix' -Because "$c can genuinely be corrected"
            # LAB-UX-1: this asked for "try it again" in the text. The page adds
            # the retry for every afterFix reason, so the machine's panel said it
            # twice. The rule is unchanged - the correction comes first - and
            # the correction is what is checked now.
            $r.whatToDo | Should -Match '(?i)^(Patch this machine|Move the listed files)' `
                -Because "$c must still name the correction first"
            $r.whatToDo | Should -Match '(?i)approver accepts the loss' `
                -Because "$c must also name the choice, which is what it lacked"
        }
    }

    It 'every choice belongs to the approver' {
        # Since 2026-09-11 every such question is the approver's. One class of answer, so an operator never has to remember
        # which of three questions they are allowed to answer.
        foreach ($r in @($script:table.reasons | Where-Object { $_.PSObject.Properties['decide'] })) {
            $r.decide.approver | Should -BeTrue -Because "$($r.code) accepts a loss"
        }
    }

    It 'the lever a decision names is one the ENGINE really reads' {
        # Read from the engine, not from a list in this file - a lever the
        # engine dropped would otherwise keep passing here for ever.
        $sm = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'PlanContract.ps1') -Raw
        # REBUILD-REMOVE-ROLE-1: no reason accepts a rebuild, and the gate that
        # read that decision (IdentityLossGate.ps1) is gone.
        foreach ($r in @($script:table.reasons | Where-Object { $_.PSObject.Properties['decide'] })) {
            $r.decide.lever | Should -Not -Be 'rebuild' -Because 'no version accepts a rebuild'
            $sm | Should -Match ([regex]::Escape($r.decide.lever)) -Because "the engine must know $($r.decide.lever)"
        }
    }

    It 'no reason tells an operator to retry something that cannot be retried' {
        # An internal contradiction the dashboard would faithfully render.
        foreach ($r in $script:table.reasons | Where-Object { $_.retry -in @('notSupported', 'outOfScope') }) {
            $r.whatToDo | Should -Not -Match 'try again' -Because "$($r.code) says retrying cannot work"
        }
    }
}

Describe 'RETRY-1: engine and guidance cannot drift apart' {
    It 'every code the engine emits has guidance' {
        $orphans = @($script:usedCodes | Where-Object { $_ -notin $script:codes })
        $orphans -join ', ' | Should -BeNullOrEmpty -Because 'a stop with no guidance is a stop an operator cannot act on'
    }

    It 'every code in the table is actually emitted' {
        $unused = @($script:codes | Where-Object { $_ -notin $script:usedCodes })
        $unused -join ', ' | Should -BeNullOrEmpty -Because 'dead guidance rots; it describes behaviour that no longer exists'
    }

    It 'EVERY handler stop carries a reason code' {
        # The real guard. A new NEEDS_DECISION or FAILED_NEEDS_ATTENTION added
        # without Reason = would otherwise reach a customer as bare engine text.
        $stops = [regex]::Matches($script:sm, "return @\{ Next = '(NEEDS_DECISION|FAILED_NEEDS_ATTENTION)';[^\r\n]*")
        @($stops).Count | Should -BeGreaterThan 8
        $missing = @($stops | Where-Object { $_.Value -notmatch "Reason\s*=" } | ForEach-Object { $_.Value.Trim() })
        $missing -join ' || ' | Should -BeNullOrEmpty
    }

    It 'and so does every multi-line stop' {
        # Two stops (NIC and data-disk capacity) are written across lines, so
        # the single-line check above cannot see them. Read the NEXT line
        # outright rather than trusting a lookahead not to backtrack past it -
        # \s+ happily matched one space and then declared "Reason" absent.
        $multi = [regex]::Matches($script:sm, "Next = '(NEEDS_DECISION|FAILED_NEEDS_ATTENTION)'\r?\n([^\r\n]*)")
        @($multi).Count | Should -BeGreaterThan 1
        $missing = @($multi | Where-Object { $_.Groups[2].Value -notmatch 'Reason\s*=' } |
            ForEach-Object { $_.Value.Trim() })
        $missing -join ' || ' | Should -BeNullOrEmpty -Because 'a stop must name its reason on the very next line'
    }

    It 'every terminal transition the engine writes names a reason' {
        # FLAKY-STOP-1: THIS CHECK FAILED IN THREE OF SIX FULL RUNS on
        # 2026-09-21 and passed every time its file was run alone. Three
        # failures taught nothing, because the suite records a test's NAME and
        # this test has two assertions with completely different causes:
        # "the pattern found too few" and "one of them really has no reason".
        #
        # Ruled out already, by checking rather than reasoning: no test writes
        # into src/, the file was not touched that day and ends with a
        # newline, and the nine files that share $script:sm all load this same
        # file.
        #
        # So the next failure carries its evidence. The length separates the
        # two remaining stories - a different input, or the same input read
        # differently - and neither can be told from a bare red line.
        #
        # THE CHECK ITSELF IS NOT LOOSENED. It guards a machine that stops
        # saying why, which is what somebody reads at two in the morning. Only
        # the failure message changes.
        $terminal = [regex]::Matches($script:sm,
            "(?s)Add-VmfStateTransition[^\r\n]*-NewState '(FAILED_NEEDS_ATTENTION|FAILED_ROLLED_BACK)'.{0,400}?(?=\r?\n\s*(break|\}|\`$doc|Write-Vmf))")
        $onDisk = if (Test-Path $script:smFile) { (Get-Content $script:smFile -Raw).Length } else { -1 }
        $evidence = "found $(@($terminal).Count) terminal transition(s); " +
                    "the text read at setup is $($script:sm.Length) characters; " +
                    "the file on disk now is $onDisk; path $($script:smFile)"
        @($terminal).Count | Should -BeGreaterThan 3 -Because $evidence
        $noCode = @($terminal | Where-Object { $_.Value -notmatch '-ReasonCode' } | ForEach-Object { $_.Value.Substring(0, 90) })
        $noCode -join ' || ' | Should -BeNullOrEmpty -Because $evidence
    }
}

Describe 'RETRY-1: classifying an exhausted step' {
    It 'names capacity, because that is the most likely retry there is' {
        # AllocationFailed is deliberately NOT in the transient list in
        # AzureOps (capacity returns in hours, not in seconds of backoff), so
        # it reaches a person - and must arrive as capacity, not as "a step
        # failed".
        foreach ($m in @(
            "AllocationFailed: Allocation failed. We do not have sufficient capacity for the requested VM size in this region.",
            "SkuNotAvailable: The requested size for resource is currently not available in centralus.")) {
            InModuleScope VmMigrationFactory -Parameters @{ m = $m } { Get-VmfErrorStopReason -Message $m } |
                Should -Be 'capacityUnavailable' -Because $m
        }
    }

    It 'names a lock, which is the one thing that fails Path B mid-flight' {
        # STOP-TEXT-SPECIFIC-1 (review): a lock that refused a change during
        # the move; Azure's words do not say the lock type.
        InModuleScope VmMigrationFactory {
            Get-VmfErrorStopReason -Message "ScopeLocked: The scope '/subscriptions/x/resourceGroups/rg' cannot perform delete operation because following scope(s) are locked"
        } | Should -Be 'resourceLockRefused'
    }

    It 'names an authorization failure' {
        InModuleScope VmMigrationFactory {
            Get-VmfErrorStopReason -Message "AuthorizationFailed: The client does not have authorization to perform action 'Microsoft.Compute/virtualMachines/write'"
        } | Should -Be 'permissionRefused' -Because 'STOP-TEXT-SPECIFIC-1: a refusal during the move is not the check before it'
    }

    It 'leaves anything it does not recognise general' {
        # A wrong code sends someone to fix the wrong thing - worse than a
        # general one. Same rule as DRIVER-1: unknown stays unknown.
        InModuleScope VmMigrationFactory {
            Get-VmfErrorStopReason -Message 'The gateway did not receive a response' | Should -Be 'stepFailedRepeatedly'
            Get-VmfErrorStopReason -Message '' | Should -Be 'stepFailedRepeatedly'
            Get-VmfErrorStopReason -Message $null | Should -Be 'stepFailedRepeatedly'
        }
    }
}

Describe 'RETRY-1: where a retry re-enters' {
    It 'a parked machine starts over - its facts were never verified' {
        InModuleScope VmMigrationFactory { Get-VmfRetryEntryState -Document ([pscustomobject]@{
            state = 'NEEDS_DECISION'
            history = @([pscustomobject]@{ outcome = 'fail'; reasonCode = 'driverBelowFloor' })
        }) } | Should -Be 'PRECHECK'
    }

    It 'a rolled-back machine starts over - it is back on its original size' {
        InModuleScope VmMigrationFactory { Get-VmfRetryEntryState -Document ([pscustomobject]@{
            state = 'FAILED_ROLLED_BACK'
            history = @([pscustomobject]@{ outcome = 'fail'; reasonCode = 'rolledBack' })
        }) } | Should -Be 'PRECHECK'
    }

    It 'only a failed validation re-validates - the conversion already succeeded' {
        InModuleScope VmMigrationFactory { Get-VmfRetryEntryState -Document ([pscustomobject]@{
            state = 'FAILED_NEEDS_ATTENTION'
            history = @([pscustomobject]@{ outcome = 'fail'; reasonCode = 'validationFailedAfterConversion' })
        }) } | Should -Be 'VALIDATING'
    }

    It 'a boot failure does NOT re-validate - there is nothing running to check' {
        InModuleScope VmMigrationFactory { Get-VmfRetryEntryState -Document ([pscustomobject]@{
            state = 'FAILED_NEEDS_ATTENTION'
            history = @([pscustomobject]@{ outcome = 'fail'; reasonCode = 'bootFailedAfterConversion' })
        }) } | Should -Be 'PRECHECK'
    }

    It 'an unknown or missing code falls back to the safe answer' {
        # PRECHECK re-verifies everything; it cannot skip a check. Ambiguity
        # must never resolve towards doing less.
        InModuleScope VmMigrationFactory {
            Get-VmfRetryEntryState -Document ([pscustomobject]@{
                state = 'FAILED_NEEDS_ATTENTION'; history = @()
            }) | Should -Be 'PRECHECK'
            Get-VmfRetryEntryState -Document ([pscustomobject]@{
                state = 'FAILED_NEEDS_ATTENTION'
                history = @([pscustomobject]@{ outcome = 'fail'; detail = 'something old with no code' })
            }) | Should -Be 'PRECHECK'
        }
    }
}

Describe 'RETRY-1: the state document records the code' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:run = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-retry-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:run -Force | Out-Null
        $script:vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; id = $script:vmId } {
            New-VmfStateDoc -RunPath $rp -VmId $id -RunId 'r1' -Wave 'w1' | Out-Null
        }
    }
    AfterAll { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'writes it, and the document still satisfies the closed schema' {
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; id = $script:vmId } {
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'NEEDS_DECISION' `
                -Outcome fail -Detail 'target size holds fewer interfaces' -ReasonCode 'targetTooFewNics'
        }
        (@($doc.history)[-1]).reasonCode | Should -Be 'targetTooFewNics'

        $schema = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        { Test-Json -Json ($doc | ConvertTo-Json -Depth 30) -SchemaFile $schema -ErrorAction Stop } | Should -Not -Throw
    }

    It 'omits it entirely on ordinary progress' {
        # An empty string would validate and then render as a blank card.
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; id = $script:vmId } {
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'PRECHECK' -Outcome ok
        }
        (@($doc.history)[-1]).PSObject.Properties.Name | Should -Not -Contain 'reasonCode'
    }

    It 'the schema declares both the reason and the machine state' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json
        # Derived, not pinned: this line was a hard-coded 6 that had to be
        # hand-edited on every bump, which makes it a chore rather than a
        # guard. What actually matters is that the schema and the writer agree.
        $store = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'StateStore.ps1') -Raw
        # StateStore writes TWO contracts now - the VM state document and, since
        # ASSESS-PAGE-1, the object manifest that says whether this is an
        # assessment or a migration. They version independently, so read the one
        # this test is about rather than "any number in the file". The original
        # assertion ("one version, not two") was true only while there was one
        # contract in here.
        $stateDoc = [regex]::Match($store, '(?s)function New-VmfStateDoc.*?
\}').Value
        $stateDoc | Should -Not -BeNullOrEmpty -Because 'the state document writer must be findable'
        # VERIFY-FP-1 part 3: the writer uses one constant, set once in the file.
        $stateDoc | Should -Match 'schemaVersion = \$script:VmfStateDocSchemaVersion'
        $written = @([regex]::Matches($store, '\$script:VmfStateDocSchemaVersion = (\d+)') | ForEach-Object { [int]$_.Groups[1].Value } | Sort-Object -Unique)
        @($written).Count | Should -Be 1 -Because 'the state document must be written at one version, not two'
        $schema.properties.schemaVersion.const | Should -Be $written[0]
        $schema.properties.history.items.properties.reasonCode.description | Should -Match 'stop-reasons'
        @($schema.properties.history.items.properties.machineState.enum) |
            Should -Be @('untouched', 'restored', 'changed')
    }

    It 'the recorded machine state is what the page uses, not the table default' {
        # FAIL-1: the same code can leave a machine untouched at precheck and
        # restored after a rollback - capacityUnavailable does exactly that -
        # so the branch that knew records it and the table entry is only a
        # fallback for documents written before the field existed.
        $script:dash | Should -Match 'stop\.machineState \?\? g\.machine'
    }

}

Describe 'RETRY-1: the dashboard can explain a stop' {
    It 'ships the same file the engine uses, rather than a copy of it' {
        $deploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $deploy | Should -Match "stop-reasons\.json"
        $deploy | Should -Match "VmMigrationFactory' 'data'"
        Test-Path (Join-Path $script:repoRoot 'src' 'dashboard' 'stop-reasons.json') |
            Should -BeFalse -Because 'a second copy in the dashboard folder is exactly the drift this avoids'
    }

    It 'reads the guidance and renders what to do' {
        $script:dash | Should -Match "fetch\('stop-reasons\.json'\)"
        $script:dash | Should -Match 'function whyStoppedCard'
        $script:dash | Should -Match 'whatToDo'
    }

    It 'falls back to the raw detail when a code has no guidance' {
        # Unknown stays unknown - the page must not invent an explanation for
        # a code it cannot resolve, and must not go blank either.
        $script:dash | Should -Match 'if \(!g\) return'
    }

    It 'every code the page names by hand exists in the table' {
        $named = @([regex]::Matches($script:dash, "reasonCode === '([a-zA-Z]+)'") | ForEach-Object { $_.Groups[1].Value }) |
            Sort-Object -Unique
        @($named).Count | Should -BeGreaterThan 0
        $missing = @($named | Where-Object { $_ -notin $script:codes })
        $missing -join ', ' | Should -BeNullOrEmpty
    }

    It 'offers the retry on a rolled-back machine' {
        $script:dash | Should -Match "'NEEDS_DECISION', 'FAILED_NEEDS_ATTENTION', 'FAILED_ROLLED_BACK'"
    }

    It 'and withholds it where this engine cannot migrate the machine at all' {
        $script:dash | Should -Match "notSupported"
    }

    It 'no longer asks the operator to choose how the engine re-enters' {
        # The invented question: "run the safety checks again" vs "only repeat
        # the final health checks" was engine vocabulary dressed as a choice.
        $script:dash | Should -Not -Match 'resolveRestart'
        $script:dash | Should -Not -Match "id: 'returnTo'"
        $script:dash | Should -Not -Match "returnTo: v\.returnTo"
    }
}

Describe 'RETRY-1: retrying a machine that was put back' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:run2 = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-retry2-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:run2 -Force | Out-Null
        $script:vm2 = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2'
        $script:planPath = Join-Path $script:run2 'plan.json'
        @{ schemaVersion = 3; assessmentRunId = 'r2'; entries = @(@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm2; wave = 'w1'; path = 'A'; policy = @{} }) } |
            ConvertTo-Json -Depth 10 | Set-Content $script:planPath -Encoding utf8
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run2; id = $script:vm2 } {
            New-VmfStateDoc -RunPath $rp -VmId $id -RunId 'r2' -Wave 'w1' | Out-Null
        }
        # RETRY-GATE-1: a retry is refused while its wave cannot start.
        . (Join-Path $PSScriptRoot '_WaveGate.ps1')
        Open-VmfTestWaveGate -RunPath $script:run2 -PlanPath $script:planPath
    }
    AfterAll { if (Test-Path $script:run2) { Remove-Item $script:run2 -Recurse -Force } }

    It 'a rolled-back machine can be retried - it used to be refused' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run2; id = $script:vm2 } {
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_ROLLED_BACK' `
                -Outcome fail -Detail 'STARTING failed; rolled back' -ReasonCode 'rolledBack' | Out-Null
        }

        $r = Resolve-VmfDecision -RunPath $script:run2 -PlanPath $script:planPath -VmId $script:vm2 `
            -Note 'capacity freed up' -ResolvedBy 'operator'
        $r.NewState | Should -Be 'PRECHECK'
        $r.ReasonCode | Should -Be 'rolledBack'
        $r.ReturnTo | Should -Be 'PRECHECK'
    }

    It 'the retry is recorded against the reason it was resolving' {
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run2; id = $script:vm2 } {
            Read-VmfStateDoc -RunPath $rp -VmId $id
        }
        (@($doc.history)[-1]).detail | Should -Match 'capacity freed up'
    }

    It 'a machine that is simply running is still refused' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run2; id = $script:vm2 } {
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'CONVERTING' -Outcome ok | Out-Null
        }
        { Resolve-VmfDecision -RunPath $script:run2 -PlanPath $script:planPath -VmId $script:vm2 `
            -Note 'no' -ResolvedBy 'operator' } | Should -Throw -ExpectedMessage '*not waiting for a person*'
    }
}
