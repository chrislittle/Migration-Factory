#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# LINUX-TEMP-1, found live in a demo, 2026-08-28. Two machines
# migrated correctly to D2ds_v6/NVMe and were then held with "Guest validation
# FAILED: fstab mounts". The guest was reporting something true - /mnt was gone
# - but the verdict was wrong in two ways, and the stakes are plain: such
# machines must not always fail.
#
#   1. The dangling entry carries `nofail`. The operating system has been told
#      explicitly that this mount may be absent; the machine boots fine. Our
#      generic check was stricter than the machine's own configuration.
#   2. Two checks disagreed. "fstab mounts" failed ANY unmounted non-root
#      entry while "temp disk mount" called a missing resource disk INFO. The
#      temp disk hits both, and the generic one silently overruled the
#      specific one.
#
# Not failing is only half an answer - a machine delivered without its
# temporary disk, silently, is worse than one held. So the engine compares
# what the machine had BEFORE with what it has after, and SAYS when the
# temporary disk did not come back.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:validate = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'guest-validate.sh') -Raw
    $script:precheck = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'nvme-check.sh') -Raw
}

Describe 'LINUX-TEMP-1: the guest stops failing a machine the OS is happy with' {
    It 'the fstab check reads mount options, so it can see nofail' {
        # It used to take only the mount point (field 2) and never look at the
        # options (field 4) - which is why a nofail entry read as a hard fault.
        $script:validate | Should -Match '\$4' -Because 'the options field decides whether an absent mount is a fault'
        $script:validate | Should -Match 'nofail'
    }

    It 'an entry marked nofail is reported, not failed' {
        $block = [regex]::Match($script:validate, '(?s)# 3\. All fstab entries.*?# 4\.').Value
        $block | Should -Match 'INFO'
        $block | Should -Match '(?i)nofail'
        # and a REQUIRED entry that is missing must still be a failure
        $block | Should -Match 'FAIL'
    }

    It 'the temp disk is judged by the temp-disk check alone, not twice' {
        $block = [regex]::Match($script:validate, '(?s)# 3\. All fstab entries.*?# 4\.').Value
        foreach ($mp in '/mnt', '/mnt/resource') {
            $block | Should -Match ([regex]::Escape($mp)) -Because 'the generic check must hand the temp disk to the check that owns it'
        }
    }

    It 'the temp-disk check reports the DEVICE and whether it is raw - facts the engine needs' {
        $block = [regex]::Match($script:validate, '(?s)# 6\. Temp disk mount.*?(\n# 7\.|\Z)').Value
        $block | Should -Match 'nvme|lsblk' -Because 'on v6 the temp disk is an NVMe namespace, and the engine compares it to the capture'
    }
}

Describe 'LINUX-TEMP-1: the machine is asked about its temp disk BEFORE it moves' {
    It 'the pre-migration check records whether a temporary disk is mounted today' {
        # Without this fact there is nothing to compare against afterwards, and
        # the loss can only ever be discovered post-migration.
        $script:precheck | Should -Match 'temp disk'
        $script:precheck | Should -Match '/mnt'
    }
}

Describe 'LINUX-TEMP-2: the engine reads the temp-disk answer from the script that GIVES it' {
    # FOUND BY THE GEN1 LAB DRILL, 2026-09-25. An Ubuntu 22.04 machine moved from
    # D2ds_v4 to D2ds_v6: /mnt was mounted before, and after the move the NVMe
    # temp disk was raw and unmounted. The engine looked for "temp disk mount"
    # in nvme-fix.sh's output - but only nvme-check.sh reports it. So the engine
    # always read "no temp disk", never installed temp-disk-setup.sh, and never
    # recorded a before-state to compare with - every Linux move from a size
    # with a temp disk to a v6 size with one lost /mnt, and PASSED.
    #
    # These RUN the engine's own GUEST_PREP, with each guest script answering
    # the way the real one does: nvme-check.sh reports the mount; nvme-fix.sh
    # does not.
    BeforeAll {
        function Global:TdPlan {
            [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/tdvm'
                wave = 'w1'; ring = 'lab'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
                    sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'; platformManaged = $false }
                target = [pscustomobject]@{ size = 'Standard_D2ds_v6'; diskArch = 'nvme-temp'; controller = 'NVMe' }
                path = 'A'
                policy = [pscustomobject]@{ onDriverBelowFloor = 'proceed' }
            }
        }
        function Global:TdGuest([string]$ScriptName, [string]$MountDetail) {
            $global:tdCalls.Add($ScriptName)
            switch ($ScriptName) {
                'nvme-check.sh' {
                    [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1'; os = 'Ubuntu 22.04'
                        result = 'READY'; warnings = @()
                        checks = @([pscustomobject]@{ name = 'temp disk mount'; status = 'INFO'; detail = $MountDetail }) }
                }
                'nvme-fix.sh' {
                    # The real nvme-fix.sh says nothing about the temp disk.
                    [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1'; os = 'Ubuntu 22.04'
                        result = 'FIXED'; warnings = @(); checks = @([pscustomobject]@{ name = 'initramfs'; status = 'FIXED'; detail = 'nvme added' }) }
                }
                default {
                    [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1'; os = 'Ubuntu 22.04'
                        result = 'READY'; warnings = @(); checks = @() }
                }
            }
        }
    }
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-td-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'td-test' | Out-Null }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        $global:tdCalls = [System.Collections.Generic.List[string]]::new()
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }
    AfterAll { Remove-Item 'function:\TdPlan', 'function:\TdGuest' -ErrorAction SilentlyContinue; Remove-Variable tdCalls -Scope Global -ErrorAction SilentlyContinue }

    It 'a machine with /mnt mounted gets the step that brings it back, and its before-state recorded' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { Global:TdGuest $ScriptName 'mounted' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:TdPlan) -RunPath $rp -RunId 'td-test'
            New-VmfStateDoc -RunPath $rp -RunId 'td-test' -VmId $ctx.VmId | Out-Null
            (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED'
            (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.tempDiskMounted | Should -BeTrue `
                -Because 'VALIDATING compares against this, and it was never recorded'
        }
        $global:tdCalls | Should -Contain 'temp-disk-setup.sh' -Because 'without it the NVMe temp disk comes back raw and /mnt is gone'
    }

    It 'a machine with no temp disk mounted is not given one' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { Global:TdGuest $ScriptName 'not mounted' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:TdPlan) -RunPath $rp -RunId 'td-test'
            New-VmfStateDoc -RunPath $rp -RunId 'td-test' -VmId $ctx.VmId | Out-Null
            Invoke-VmfStepGuestPrep -Context $ctx | Out-Null
            # -Be $false, not -BeFalse: $null (never recorded - the defect)
            # must not pass as "no temp disk".
            (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.tempDiskMounted | Should -Be $false
        }
        $global:tdCalls | Should -Not -Contain 'temp-disk-setup.sh'
    }
}

Describe 'LINUX-TEMP-1: the engine judges the comparison, and never silently loses a drive' {
    BeforeAll {
        function Script:Facts([bool]$before, [bool]$after, [string]$afterDetail = '') {
            $cap = [pscustomobject]@{ tempDiskMounted = $before }
            $checks = @(
                [pscustomobject]@{ name = 'temp disk mount'; status = $(if ($after) { 'PASS' } else { 'INFO' })
                                   detail = $(if ($afterDetail) { $afterDetail } else { if ($after) { 'mounted at /mnt' } else { 'not mounted' } }) }
            )
            @{ Captured = $cap; Checks = $checks }
        }
    }

    It 'a temporary disk that was there before and is gone after is REPORTED, not failed' {
        $f = Script:Facts $true $false
        InModuleScope VmMigrationFactory -Parameters @{ f = $f } {
            $r = Test-VmfTempDiskOutcome -CapturedMounted $f.Captured.tempDiskMounted -Checks $f.Checks
            $r.Ok | Should -BeTrue -Because 'such machines must not always fail'
            $r.Changed | Should -BeTrue
            $r.Detail | Should -Match '(?i)temporary disk'
            $r.Detail | Should -Match '(?i)was mounted before'
        }
    }

    It 'a temporary disk that comes back is not remarked on' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (Script:Facts $true $true) } {
            $r = Test-VmfTempDiskOutcome -CapturedMounted $f.Captured.tempDiskMounted -Checks $f.Checks
            $r.Ok | Should -BeTrue
            $r.Changed | Should -BeFalse
        }
    }

    It 'a machine that never had one is not given news about it' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (Script:Facts $false $false) } {
            $r = Test-VmfTempDiskOutcome -CapturedMounted $f.Captured.tempDiskMounted -Checks $f.Checks
            $r.Changed | Should -BeFalse
        }
    }

    It 'an UNKNOWN before-state stays unknown - it is never read as "it was fine"' {
        # Machines migrated before this fact existed have no captured value.
        InModuleScope VmMigrationFactory {
            $checks = @([pscustomobject]@{ name = 'temp disk mount'; status = 'INFO'; detail = 'not mounted' })
            $r = Test-VmfTempDiskOutcome -CapturedMounted $null -Checks $checks
            $r.Ok | Should -BeTrue
            $r.Changed | Should -BeFalse
            $r.Detail | Should -Match '(?i)cannot be compared|is not known'
        }
    }
}
