#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SAFETY-2: the safety copy was taken while the machine was
# still RUNNING and AFTER guest prep had already rewritten the boot path -
# initramfs and GRUB on Linux, boot-driver registry across every ControlSet on
# Windows. So the one artefact the whole rollback story rests on was a
# CRASH-CONSISTENT image of an ALREADY MODIFIED machine. It may not even boot.
#
# Sequence C was chosen, accepting the extra downtime:
#
#   PRECHECK -> stop -> SNAPSHOT A (pristine)  -> start
#            -> GUEST_PREP -> stop -> SNAPSHOT B (prepared) -> CONVERTING
#
# Two snapshots, both INCREMENTAL: A stores the used blocks, B stores only what
# guest prep changed. And note the ordering makes the fused prep/deallocate
# rule in CLAUDE.md STRICTER, not looser - prep is now immediately followed by
# the stop, with nothing in between.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:SafePlan {
        param([string]$Os = 'Linux', [string]$Copy = 'pristine', [string]$Controller = 'NVMe')
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion)
            vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/safevm'
            wave = 'w1'; ring = 'lab'
            assessment = [pscustomobject]@{
                classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'
                platformManaged = $false; location = 'centralus'
            }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = $Controller }
            path = 'A'
            policy = [pscustomobject]@{ safetyCopy = $Copy; onIacManaged = 'proceed' }
        }
    }
}
AfterAll { Remove-Item 'function:\SafePlan' -ErrorAction SilentlyContinue }

Describe 'SAFETY-2: the order puts every snapshot on a stopped machine' {
    It 'the state table carries the pristine step' {
        InModuleScope VmMigrationFactory {
            $handlers = InModuleScope VmMigrationFactory { $null }   # placeholder
        }
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        $src | Should -Match 'SAFETY_PRISTINE'
        $src | Should -Match 'Invoke-VmfStepSafetyPristine'
    }

    It 'PRECHECK now hands off to the pristine copy, not straight to prep' {
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        $src | Should -Match "Next = 'SAFETY_PRISTINE'"
    }

    It 'guest prep is IMMEDIATELY followed by the stop - the fused rule gets stricter' {
        # CLAUDE.md: Windows re-creates stornvme StartOverride on every SCSI
        # boot, so nothing may come between prep and deallocation. The old
        # order put a snapshot in that gap; this one does not.
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        $src | Should -Match "return @\{ Next = 'STOPPED' \}"
        $src | Should -Not -Match "return @\{ Next = 'SAFETY_COPY'; Detail = 'SCSI target"
    }

    It 'the prepared copy is taken AFTER the machine is stopped' {
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        # STOPPED hands to SAFETY_COPY, and SAFETY_COPY hands to CONVERTING
        $src | Should -Match "Next = 'SAFETY_COPY'; Detail = 'deallocated"
        $src | Should -Match "Next = 'CONVERTING'; Detail = \`"The second safety copy is "
    }
}

Describe 'SAFETY-2: both snapshots are incremental' {
    It 'the snapshot helper asks for an incremental snapshot' {
        # Two FULL copies per machine would double the storage bill for no
        # restore benefit: A stores the used blocks, B only what prep changed.
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1') -Raw
        # SAFETY-CMK-1 builds the configuration as a splat, to add the disk's
        # encryption: the switch is now 'Incremental = $true'.
        $src | Should -Match 'New-AzSnapshotConfig @configArgs'
        $src | Should -Match '\$configArgs = @\{ SourceUri = \$OsDiskId; Location = \$Location; CreateOption = ''Copy''; Incremental = \$true \}'
    }

    It 'and says why, because the constraint is not obvious' {
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1') -Raw
        $src | Should -Match '(?i)same subscription and region|Standard HDD'
    }
}

Describe 'SAFETY-2: the pristine copy is taken on a stopped machine, then it is restarted' {
    BeforeEach {
        # ROLLBACK-DISKS-FIRST-1: the rollback disks, made at the end of
        # SAFETY_PRISTINE, are the subject of RollbackDisksBeforeMove.Tests.ps1; here the copies are.
        Mock -ModuleName VmMigrationFactory New-VmfRollbackDisksBeforeMove { $null }
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-saf-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'saf-test' | Out-Null
        }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { '/snap/pristine' }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { '/snap/pristine/providers/Microsoft.Authorization/locks/vmf-safety-copy' }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'stops the machine BEFORE snapshotting - that is the whole point' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:SafePlan) -RunPath $rp -RunId 'saf-test'
            New-VmfStateDoc -RunPath $rp -RunId 'saf-test' -VmId $ctx.VmId | Out-Null
            $vc = @{ osDisk = @{ managedDiskId = '/disks/os' }; location = 'centralus'; capacityReservationGroupId = $null; patchSettings = $null }
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = $vc; original = @{ vmConfig = $vc } }
            $r = Invoke-VmfStepSafetyPristine -Context $ctx
            $r.Next | Should -Be 'GUEST_PREP'
        }
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 1
        Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -Times 1
    }

    It 'restarts it afterwards, or guest prep could never run' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:SafePlan) -RunPath $rp -RunId 'saf-test'
            New-VmfStateDoc -RunPath $rp -RunId 'saf-test' -VmId $ctx.VmId | Out-Null
            $vc = @{ osDisk = @{ managedDiskId = '/disks/os' }; location = 'centralus'; capacityReservationGroupId = $null; patchSettings = $null }
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = $vc; original = @{ vmConfig = $vc } }
            Invoke-VmfStepSafetyPristine -Context $ctx | Out-Null
        }
        Should -Invoke -ModuleName VmMigrationFactory Start-VmfVm -Times 1
    }

    It 'records the pristine snapshot SEPARATELY from the prepared one' {
        # Restore has to be able to choose: "as it was" or "ready to convert".
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:SafePlan) -RunPath $rp -RunId 'saf-test'
            New-VmfStateDoc -RunPath $rp -RunId 'saf-test' -VmId $ctx.VmId | Out-Null
            $vc = @{ osDisk = @{ managedDiskId = '/disks/os' }; location = 'centralus'; capacityReservationGroupId = $null; patchSettings = $null }
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = $vc; original = @{ vmConfig = $vc } }
            Invoke-VmfStepSafetyPristine -Context $ctx | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId
            $doc.safety.pristineSnapshotId | Should -Be '/snap/pristine'
        }
    }

    It 'never skips the copy, even when a plan says clean' {
        # Rewritten for SAFETYCOPY-CLEAN-1 (decided 2026-10-04). This
        # test pinned the old skip: a `clean` entry went on to guest prep with
        # no first copy, and so with no way back. PRECHECK now refuses such an
        # entry (SafetyCopyClean.Tests.ps1); this step no longer reads the
        # setting, so whatever reaches it gets its copy.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:SafePlan -Copy 'clean') -RunPath $rp -RunId 'saf-test'
            New-VmfStateDoc -RunPath $rp -RunId 'saf-test' -VmId $ctx.VmId | Out-Null
            $vc = @{ osDisk = @{ managedDiskId = '/disks/os' }; location = 'centralus'; capacityReservationGroupId = $null; patchSettings = $null }
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = $vc; original = @{ vmConfig = $vc } }
            $r = Invoke-VmfStepSafetyPristine -Context $ctx
            $r.Next | Should -Be 'GUEST_PREP'
            $r.Detail | Should -Not -Match '(?i)not requested'
        }
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 1
        Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -Times 1
    }
}

Describe 'SAFETY-2: prod asks for the pristine copy by default' {
    It 'the wave default gives EVERY wave the pristine copy' {
        # This began as "prod pristine, lab cheap" - a trade I made rather
        # than a requirement (corrected 2026-08-27), then the ring
        # taxonomy itself died (WAVE-2). One default set now, and the pristine
        # copy is in it unconditionally: going back to the beginning is the
        # core promise, not a premium feature of an environment word.
        InModuleScope VmMigrationFactory {
            (Get-VmfDefaultWavePolicy).safetyCopy | Should -Be 'pristine'
            (Get-VmfDefaultWavePolicy -CapacityGateOverride 'Reserved').safetyCopy | Should -Be 'pristine'
        }
    }
}

Describe 'SAFETY-2: restore can choose which copy to go back to' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:restoreSrc = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Restore-VmfVm.ps1') -Raw
    }

    It 'offers prepared and pristine, and defaults to the safe-to-resume one' {
        $script:restoreSrc | Should -Match "ValidateSet\('prepared', 'pristine'\)"
        $script:restoreSrc | Should -Match "\`$From = 'prepared'"
    }

    It 'reads the pristine id when asked for it' {
        $script:restoreSrc | Should -Match 'pristineSnapshotId'
    }

    It 'explains itself when no first safety copy exists, rather than failing obscurely' {
        # "snapshot not found" would send someone hunting for a bug. Every move
        # takes the first copy (no wave takes only the second), so this is a
        # guard. MANUAL-REVIEW-1: it names no cmdlet parameter (hard rule 12).
        $script:restoreSrc | Should -Match "holds no first safety copy, so the restore cannot use it"
        $script:restoreSrc | Should -Not -Match '(?i)Restore with -From'
    }

    It 'records WHICH copy was used, because the two mean different things' {
        $script:restoreSrc | Should -Match 'fromCopy'
    }
}

Describe 'SAFETY-2: a pristine restore has to revert the hardware too' {
    # Caught by reading the restore path rather than by drilling it: restore is
    # CONTENT ONLY, so putting the pristine disk on a machine already resized
    # to NVMe hands it an initramfs with no NVMe driver on a controller that
    # needs one. It would not boot - a safety copy nobody can actually use.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:rs = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Restore-VmfVm.ps1') -Raw
    }

    It 'reverts size and controller when restoring the pristine copy' {
        $script:rs | Should -Match "if \(\`$From -eq 'pristine'\)"
        $script:rs | Should -Match 'Set-VmfVmSizeAndController'
        $script:rs | Should -Match 'capturedSize'
    }

    It 'does it while the machine is still stopped, before the start' {
        $revert = $script:rs.IndexOf("restore:revertHardware")
        $start = $script:rs.IndexOf("restore:start")
        $revert | Should -BeGreaterThan 0
        $revert | Should -BeLessThan $start -Because 'a resize needs the machine deallocated'
    }

    It 'says why in the record, since a size change during a restore looks alarming' {
        # RESTORE-WARN-ENDS-1: the run page now shows this line as written, so
        # it is a sentence that names the first safety copy.
        $script:rs | Should -Match '(?i)The first safety copy is from before the guest changes'
    }

    It 'leaves the PREPARED restore alone - it boots on the new hardware' {
        # The prepared copy was taken with prep applied, so reverting its
        # hardware would be wrong, not merely unnecessary.
        # RESTORE-END-JOB-1: the branch also skips a resume whose job saved the
        # hardware step already (-and -not $hardwareDone).
        $script:rs | Should -Match "(?s)if \(\`$From -eq 'pristine'( -and -not \`$hardwareDone)?\).{0,2400}Set-VmfVmSizeAndController"
    }
}

Describe 'SAFETY-2: the two snapshot ids must both survive' {
    BeforeEach {
        $script:mergePath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-mrg-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:mergePath } {
            Initialize-VmfRun -RunPath $rp -RunId 'mrg-test' | Out-Null
        }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
    }
    AfterEach { if (Test-Path $script:mergePath) { Remove-Item $script:mergePath -Recurse -Force } }

    It 'the prepared copy does not erase the pristine one' {
        # THE drill's finding. Each step was correct in isolation, so no unit
        # test caught it: SAFETY_COPY assigned a fresh safety object and wiped
        # the id SAFETY_PRISTINE had written. The snapshot existed in Azure and
        # the machine had no record of it, so restore refused.
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { '/snap/pristine' }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { '/snap/pristine/providers/Microsoft.Authorization/locks/vmf-safety-copy' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:mergePath } {
            $ctx = New-VmfContext -PlanEntry (Global:SafePlan) -RunPath $rp -RunId 'mrg-test'
            New-VmfStateDoc -RunPath $rp -RunId 'mrg-test' -VmId $ctx.VmId | Out-Null
            $vc = @{ osDisk = @{ managedDiskId = '/disks/os' }; location = 'centralus'; capacityReservationGroupId = $null; patchSettings = $null }
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = $vc; original = @{ vmConfig = $vc } }
            Invoke-VmfStepSafetyPristine -Context $ctx | Out-Null
        }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { '/snap/prepared' }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { '/snap/prepared/providers/Microsoft.Authorization/locks/vmf-safety-copy' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:mergePath } {
            $ctx = New-VmfContext -PlanEntry (Global:SafePlan) -RunPath $rp -RunId 'mrg-test'
            Invoke-VmfStepSafetyCopy -Context $ctx | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId
            $doc.safety.pristineSnapshotId | Should -Be '/snap/pristine' -Because 'the pristine id must survive the second copy'
            $doc.safety.snapshotId | Should -Be '/snap/prepared'
        }
    }
}

Describe 'SAFETY-2: reserved capacity is ONE WAY, so the put-back leaves it' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $src = Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'VmMigrationFactory'
        # Code only: a comment that names the leave must not pass these checks.
        $script:rr = Get-VmfCodeOnly -Path (Join-Path $src 'Public' 'Restore-VmfVm.ps1')
        $script:crgCode = Get-VmfCodeOnly -Path (Join-Path $src 'Private' 'engine' 'ReservationPutBack.ps1')
    }

    # Found live by the SAFETY-2 drill, and confirmed: a reservation group is
    # created to hold the v6 TARGET and nothing ever reserves the original size.
    # Reverting the size while still associated is refused outright:
    #   "Capacity Reservation with VM size Standard_D2s_v4 does not exist in the
    #    Capacity Reservation Group '...'"  (409 OperationNotAllowed)
    # and it fails INSIDE the stopped window - the safety net tearing at the one
    # moment it exists for. ROLLBACK-CRG-1: the leave is now one shared step,
    # which leaves only a group the machine was not in before the move; its
    # behaviour is tested in RollbackCrg.Tests.ps1.

    It 'detaches from the reservation group during a pristine put-back' {
        $script:rr | Should -Match "Invoke-VmfReservationLeave .*-Kind 'restore'"
        $script:crgCode | Should -Match 'leaveReservation'
        $script:crgCode | Should -Match 'Set-VmfVmCapacityReservationGroup .*-GroupId \$null'
    }

    It 'and does it BEFORE the size changes, which is the whole point' {
        $leave = $script:rr.IndexOf('Invoke-VmfReservationLeave')
        $revert = $script:rr.IndexOf('restore:revertHardware')
        $leave | Should -BeGreaterThan 0
        $revert | Should -BeGreaterThan 0
        $leave | Should -BeLessThan $revert -Because 'detaching after the size change is exactly the 409 the drill hit'
    }

    It 'only inside the pristine branch - a prepared restore stays on the new size, and its reservation' {
        # RESTORE-END-JOB-1: a resume past the hardware step skips the branch.
        $script:rr | Should -Match "(?s)if \(\`$From -eq 'pristine'( -and -not \`$hardwareDone)?\).{0,1200}Invoke-VmfReservationLeave"
    }

    It 'never tries to reserve the original size instead' {
        # Reservations are one way. Creating a v4 reservation to put a machine
        # back would bill for capacity the migration exists to stop paying for.
        $script:rr | Should -Not -Match 'New-VmfCapacityReservation'
        $script:crgCode | Should -Not -Match 'New-VmfCapacityReservation'
    }

    It 'tells the operator it let the capacity go' {
        $script:crgCode | Should -Match '(?i)left the capacity reservation group'
    }
}
Describe 'SAFETY-2: the in-use count comes back down when a machine leaves' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:orch = Get-Content (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'VmMigrationFactory' 'Private' 'engine' 'Orchestrator.ps1') -Raw
    }

    It 'has a removal to match the addition' {
        # "In use" is our own ledger, incremented when a VM joins a reservation.
        # Nothing ever decremented it, so the put-back - which now detaches,
        # because reservations are one way - would have left the panel reporting
        # capacity in use with nothing on it.
        $script:orch | Should -Match 'function Remove-VmfClaimAssociation'
        $script:orch | Should -Match '\$claim\.reservation\.consumedInstances = @\(\$remaining\)\.Count'
    }

    It 'and the put-back calls it' {
        # ROLLBACK-CRG-1: through the shared leave every put-back uses.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $crg = Get-VmfCodeOnly -Path (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'VmMigrationFactory' 'Private' 'engine' 'ReservationPutBack.ps1')
        $crg | Should -Match 'Remove-VmfClaimAssociation -RunPath \$RunPath -VmId \$VmId'
    }

    It 'the count tracks the list, in both directions' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-cap-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                Initialize-VmfRun -RunPath $rp -RunId 'cap-test' | Out-Null
                $claim = [ordered]@{ schemaVersion = 1; wave = 'w1'; size = 'Standard_D2s_v6'; region = 'centralus'
                                     zone = $null; state = 'RESERVED'
                                     reservation = [ordered]@{ createdUtc = '2026-08-27T00:00:00Z'; releasedUtc = $null; consumedInstances = 0 } }
                Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/w1.json' -Document $claim -Depth 12

                Add-VmfClaimAssociation -RunPath $rp -ClaimRelPath 'capacity/w1.json' -VmId '/vm/a'
                Add-VmfClaimAssociation -RunPath $rp -ClaimRelPath 'capacity/w1.json' -VmId '/vm/b'
                $two = Read-VmfStoreJson -RunPath $rp -RelPath 'capacity/w1.json' -Depth 12
                $two.reservation.consumedInstances | Should -Be 2

                Remove-VmfClaimAssociation -RunPath $rp -VmId '/vm/a'
                $one = Read-VmfStoreJson -RunPath $rp -RelPath 'capacity/w1.json' -Depth 12
                $one.reservation.consumedInstances | Should -Be 1
                @($one.associatedVmIds) | Should -Be @('/vm/b')

                # a VM that was never on it changes nothing
                Remove-VmfClaimAssociation -RunPath $rp -VmId '/vm/zzz'
                (Read-VmfStoreJson -RunPath $rp -RelPath 'capacity/w1.json' -Depth 12).reservation.consumedInstances | Should -Be 1
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'SAFETY-2: the shutdown before the pristine copy is VISIBLE' {
    # The logs showed no machine shutdown event before the safety copy, so a
    # reader could not check that the stop happened.
    #
    # Two separate things were wrong with that picture, and only one was the UI.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:smSrc = Get-Content (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        $script:uiSrc = (Get-VmfPageSource -Path (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'dashboard' 'migrations.html'))
        $script:pristineStep = [regex]::Match($script:smSrc, '(?s)function Invoke-VmfStepSafetyPristine.*?\n\}').Value
    }

    It 'the step really does stop, then snapshot, then start - in that order' {
        # The claim itself, checked against the code rather than a screenshot.
        # Match the OPERATION, not the bare word: the step's doc comment names
        # pristineSnapshot before any code runs, so a plain IndexOf finds the
        # explanation rather than the call and reports the wrong order.
        $opIndex = {
            param([string]$Name)
            [regex]::Match($script:pristineStep, "Invoke-VmfAzOperation\s+-Name\s+'$Name'").Index
        }
        $stop = & $opIndex 'deallocateForPristine'
        $snap = & $opIndex 'pristineSnapshot'
        # SAFETY-ALL-1: a resume that only has data disks left starts the
        # machine in its own branch, before the first copy's code - the start
        # that follows the copies is the LAST one.
        $start = [regex]::Matches($script:pristineStep, "Invoke-VmfAzOperation\s+-Name\s+'startAfterPristine'")[-1].Index
        $stop | Should -BeGreaterThan 0
        $snap | Should -BeGreaterThan 0
        $start | Should -BeGreaterThan 0
        $stop | Should -BeLessThan $snap -Because 'a copy taken while the machine runs is not a copy of a stopped machine'
        $snap | Should -BeLessThan $start -Because 'starting before the copy would defeat the point of stopping'
    }

    It 'and each of those three steps is named in the feed, so the order can be READ' {
        # An unlabelled step does not merely lose detail - it removes evidence
        # of the sequence, which is what UI-ORDER-1 was about.
        # UiTellsTheTruth already proves NO operation falls through to the
        # catch-all, generally. This asserts the three that carry the ORDER are
        # each named by a pattern about them - stated plainly rather than
        # reconstructing the phrase table with a regex, which is how the first
        # version of this test broke itself.
        $script:uiSrc | Should -Match 'deallocate' -Because 'the shutdown must be named'
        $script:uiSrc | Should -Match 'pristineSnapshot' -Because 'the pristine copy must be named case-insensitively - it was not, and the snapshot vanished from the feed'
        $script:uiSrc | Should -Match 'azureops:start' -Because 'the restart must be named'

        # and the SPECIFIC pristine pattern must come before the general
        # snapshot one, or the specific step is swallowed by the general.
        $iPristine = $script:uiSrc.IndexOf('pristineSnapshot/i')
        $iGeneral  = $script:uiSrc.IndexOf('snapshot/i,')
        $iPristine | Should -BeGreaterThan 0
        $iPristine | Should -BeLessThan $iGeneral
    }

    It 'a SKIPPED pristine step does not claim a copy was taken' {
        # THE actual defect. On a ring whose policy is a clean copy this step
        # returns in a second having done nothing, and the feed still said
        # "Taking a safety copy of the machine exactly as it is now" - so the
        # safety net appeared to have run, and the absent shutdown looked like
        # OUR bug rather than a step that never acted.
        # SAFETYCOPY-CLEAN-1: the engine never skips this step, and nothing is
        # public before 1.0, so no run holds a "not requested" line
        # (MANUAL-REVIEW-1): the page has no sentence for one.
        $script:uiSrc | Should -Match "e\.step === 'SAFETY_PRISTINE' && e\.outcome === 'ok'"
        $script:uiSrc | Should -Not -Match 'pristineNotRequested'
        $script:uiSrc | Should -Not -Match '(?i)does not ask for a copy'
    }

    It 'and when it DID take one, it says the machine was stopped for it' {
        # The evidence a reader looks for, stated in the line itself
        # rather than only inferable from neighbouring events.
        $script:uiSrc | Should -Match '(?i)machine was stopped'
        $script:uiSrc | Should -Match '(?i)nothing had been changed'
    }

    It 'the resumed case is honest too - already taken is not taken again' {
        $script:uiSrc | Should -Match 'pristineAlready'
        $script:uiSrc | Should -Match '(?i)already taken earlier in this migration'
    }
}

Describe 'SAFETY-2: EVERY ring can go back to the beginning' {
    # The ring table gave only prod a copy taken BEFORE guest prep. That was an
    # engineering trade I made - the extra stop/start looked unjustified below
    # prod - and it was not mine to make: it silently removed the ability to put
    # a machine back the way it started on every ring except one. Being able to
    # return to the beginning is the core promise of this tool, not a premium
    # feature of the production ring.
    It 'the default set carries the pristine copy - there is no ring to hide a cheaper trade in' {
        InModuleScope VmMigrationFactory {
            (Get-VmfDefaultWavePolicy).safetyCopy | Should -Be 'pristine' -Because 'every wave must be able to roll back to the beginning'
        }
    }

    It 'and a plan that says nothing still gets one' {
        # A plan written without thinking about the safety copy must not lose
        # the guarantee quietly. The engine default is the last line of defence.
        InModuleScope VmMigrationFactory {
            $entry = [pscustomobject]@{ policy = [pscustomobject]@{}; target = [pscustomobject]@{ controller = 'NVMe' } }
            Get-VmfPolicy -PlanEntry $entry -Name 'safetyCopy' | Should -Be 'pristine'
        }
    }

    It 'the reason is written down, because the cost is real and someone will question it' {
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'Planner.ps1') -Raw
        $src | Should -Match '(?i)not a lever: the failure model depends on it'
        $src | Should -Match '(?i)safe end is the default'
    }
}
