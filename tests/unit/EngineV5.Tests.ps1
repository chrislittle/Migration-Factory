#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# GEN-V5-1 C4/C5: what the engine does on a move to a v5 size.
#
# Before v5, "the target controller is SCSI" meant only one thing: a SCSI
# REVERSION (the SCSI-direction drill), where the machine needs no preparation
# and accelerated networking is left as it was. A v5 move is also SCSI, and it
# is not that:
#   - MANA reaches Intel v5 hosts (from 2026-05-26), so the MANA driver question
#     applies to Intel v5 exactly as it does to v6 - and not to AMD v5, whose
#     pages list NetVSC and ConnectX only;
#   - Intel D v5 REQUIRES accelerated networking, and Intel E v5 since
#     2026-10-01 (DRIFT-5). Microsoft's v5 guide: "Enable
#     Accelerated Networking on the source VM before you resize to a series
#     that requires it". A machine with it off stops before it is touched, and
#     an approver can accept turning it on;
#   - a Windows machine that loses its temporary disk still needs its page file
#     moved - that is about the disk, not the controller;
#   - nothing NVMe runs: no guest NVMe preparation, no disk controller patch;
#   - a Generation 1 machine must not be given a controller setting, which
#     Azure refuses for Generation 1 (ROLLBACK-NULL-1).
# So the engine names three kinds of move and asks the target SIZE, not the
# controller, about the network.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    function Global:V5Nics([bool]$PrimaryOn) {
        , @([pscustomobject]@{ id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic0'; primary = $true; acceleratedNetworking = $PrimaryOn })
    }
    function Global:V5Plan([string]$Size = 'Standard_D2ds_v5', [string]$Controller = 'SCSI', [string]$Os = 'Linux',
                           [string]$An = '', [string]$OnFloor = 'stop', [string]$Path = 'A',
                           [string]$SourceArch = 'scsi-temp', [string]$TargetArch = 'scsi-temp') {
        $policy = [ordered]@{ onDriverBelowFloor = $OnFloor; onDDataFound = 'stop' }
        if ($An) { $policy.acceleratedNetworking = $An }
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion)
            vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/v5vm'
            wave = 'w1'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V1'; os = $Os
                sourceSize = 'Standard_D2s_v3'; sourceDiskArch = $SourceArch; platformManaged = $false }
            target = [pscustomobject]@{ size = $Size; diskArch = $TargetArch; controller = $Controller }
            path = $Path
            policy = [pscustomobject]$policy
        }
    }
}
AfterAll { Remove-Item 'function:\V5Nics', 'function:\V5Plan' -ErrorAction SilentlyContinue }

Describe 'GEN-V5-1 C4: three kinds of move' {

    It '<Size>/<Controller> is a <Kind>' -ForEach @(
        @{ Size = 'Standard_D2ds_v6'; Controller = 'NVMe'; Kind = 'nvme-conversion' }
        @{ Size = 'Standard_D2ds_v5'; Controller = 'SCSI'; Kind = 'scsi-resize' }
        @{ Size = 'Standard_E4as_v5'; Controller = 'SCSI'; Kind = 'scsi-resize' }
        @{ Size = 'Standard_D2ds_v6'; Controller = 'SCSI'; Kind = 'scsi-reversion' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ p = (Global:V5Plan -Size $Size -Controller $Controller); kind = $Kind } {
            Get-VmfMoveKind -PlanEntry $p | Should -Be $kind
        }
    }
}

Describe 'GEN-V5-1 C5: accelerated networking on a v5 move' {

    It 'the default for a v5 move is to turn it on, as for v6 and v7 (a ruling); a reversion keeps it as it was' {
        InModuleScope VmMigrationFactory {
            Get-VmfPolicy -PlanEntry (Global:V5Plan) -Name 'acceleratedNetworking' | Should -Be 'ensureOn'
            Get-VmfPolicy -PlanEntry (Global:V5Plan -Size 'Standard_D2ds_v6' -Controller 'SCSI') -Name 'acceleratedNetworking' | Should -Be 'preserve'
            Get-VmfPolicy -PlanEntry (Global:V5Plan -Size 'Standard_D2ds_v6' -Controller 'NVMe') -Name 'acceleratedNetworking' | Should -Be 'ensureOn'
        }
    }

    It 'Intel D v5, on before, driver present: on, and an accelerated adapter is expected after the move' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:V5Plan) -CapturedNics (Global:V5Nics $true) -ManaDriver 'present'
            $r.Stop | Should -BeFalse
            $r.Policy | Should -Be 'ensureOn'
            $r.ExpectFabric | Should -BeTrue
        }
    }

    It 'Intel D v5 REQUIRES it: off before - stop before the machine is touched' {
        InModuleScope VmMigrationFactory {
            foreach ($driver in 'present', 'absent', 'unknown') {
                $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:V5Plan) -CapturedNics (Global:V5Nics $false) -ManaDriver $driver
                $r.Stop | Should -BeTrue -Because "driver $driver"
                $r.Reason | Should -Be 'acceleratedNetworkingRequired'
                $r.Detail | Should -Match 'Standard_D2ds_v5'
            }
        }
    }

    It 'and a wave that keeps it OFF on Intel D v5 stops too - Azure requires it there' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:V5Plan -An 'preserve') -CapturedNics (Global:V5Nics $false) -ManaDriver 'present'
            $r.Stop | Should -BeTrue
            $r.Reason | Should -Be 'acceleratedNetworkingRequired'
        }
    }

    It 'an approver who accepted turning it on: it moves, and the move turns it on' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:V5Plan -An 'ensureOn') -CapturedNics (Global:V5Nics $false) -ManaDriver 'present'
            $r.Stop | Should -BeFalse
            $r.Policy | Should -Be 'ensureOn'
        }
    }

    # DRIFT-5 rewrote this test. It said Intel E v5 does not require accelerated
    # networking, so a Linux machine with it off and no MANA driver was kept off
    # (AN-KEEP-1). On 2026-10-01 Microsoft changed the Ev5, Esv5, Edv5 and Edsv5
    # pages to "Required". Intel E v5 now stops like Intel D v5, and the
    # keep-off case is left to v6 and v7, where it is still true.
    It 'Intel E v5 REQUIRES it too (DRIFT-5): off before - stop before the machine is touched' {
        InModuleScope VmMigrationFactory {
            foreach ($size in 'Standard_E2ds_v5', 'Standard_E2s_v5', 'Standard_E2_v5', 'Standard_E2d_v5') {
                foreach ($driver in 'present', 'absent', 'unknown') {
                    $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:V5Plan -Size $size) -CapturedNics (Global:V5Nics $false) -ManaDriver $driver
                    $r.Stop | Should -BeTrue -Because "$size, driver $driver"
                    $r.Reason | Should -Be 'acceleratedNetworkingRequired'
                    $r.Detail | Should -Match ([regex]::Escape($size))
                }
            }
        }
    }

    It 'AMD E v5 still does not require it: off before, nothing stops' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:V5Plan -Size 'Standard_E2ads_v5') -CapturedNics (Global:V5Nics $false) -ManaDriver 'absent'
            $r.Stop | Should -BeFalse
        }
    }

    # DRIFT-11: every v6 size requires it since 2026-10-27, so the keep-off
    # case is held on v7 now.
    # AN-MANA-DRIVER-RULE-1 (2026-11-06): rewritten. It was kept off on
    # v7 (AN-KEEP-1); no size that can give MANA keeps it off now, so the move
    # stops for the driver, untouched.
    It 'off before, no MANA driver, on v7 - the driver stop, never kept off' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:V5Plan -Size 'Standard_E2ds_v7' -Controller 'NVMe') -CapturedNics (Global:V5Nics $false) -ManaDriver 'absent'
            $r.Stop | Should -BeTrue
            $r.Reason | Should -Be 'driverBelowFloor'
            $r.Policy | Should -Not -Be 'preserve'
        }
    }

    It 'Intel v5 can give MANA: on before, no driver - the driver stop, as on v6' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:V5Plan -Size 'Standard_E2ds_v5') -CapturedNics (Global:V5Nics $true) -ManaDriver 'unlisted'
            $r.Stop | Should -BeTrue
            $r.Reason | Should -Be 'driverBelowFloor'
        }
    }

    It 'AMD v5 cannot give MANA: a missing MANA driver changes nothing' {
        InModuleScope VmMigrationFactory {
            foreach ($on in $true, $false) {
                $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:V5Plan -Size 'Standard_D2ads_v5') -CapturedNics (Global:V5Nics $on) -ManaDriver 'absent'
                $r.Stop | Should -BeFalse -Because "on before = $on"
                $r.Policy | Should -Be 'ensureOn'
                $r.ExpectFabric | Should -BeTrue
            }
        }
    }

    It 'the words a person reads name the size and Microsoft''s step' {
        $table = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
        $r = @($table.reasons | Where-Object code -eq 'acceleratedNetworkingRequired')[0]
        $r | Should -Not -BeNullOrEmpty
        $r.machine | Should -Be 'untouched'
        $r.decide.lever | Should -Be 'acceleratedNetworking'
        $r.decide.accept | Should -Be 'ensureOn'
        $r.decide.approver | Should -BeTrue
        $r.meaning | Should -Match '(?i)accelerated networking'
    }
}

Describe 'GEN-V5-1 C4: RUN the preparation step for a v5 move' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-v5-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'v5-test' | Out-Null }
        $global:v5Scripts = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            $global:v5Scripts.Add($ScriptName)
            # MANA-WIN-1: the machine's driver store already has MANA.
            if ($ScriptName -eq 'Install-ManaDriver.ps1') { return [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1'; result = 'NO_CHANGE'; warnings = @(); checks = @() } }
            $facts = [pscustomobject]@{ os = 'Linux'; kernelVersion = '5.15.0-1100-azure'; distroId = 'ubuntu'; distroVersion = '22.04'; fabric = 'mlx' }
            [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1'; os = 'x'; result = 'READY'; warnings = @()
                checks = @([pscustomobject]@{ name = 'mana module available'; status = 'PASS'; detail = 'modinfo mana' }); facts = $facts }
        }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
        Remove-Variable v5Scripts -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Linux to Intel D v5, on before: the driver is checked and NOTHING NVMe runs' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:V5Plan) -RunPath $rp -RunId 'v5-test'
            New-VmfStateDoc -RunPath $rp -RunId 'v5-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:V5Nics $true) } }
            (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED'
            (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.acceleratedNetworking.policy | Should -Be 'ensureOn'
        }
        $global:v5Scripts | Should -Contain 'mana-check.sh'
        $global:v5Scripts | Should -Not -Contain 'nvme-fix.sh'
        $global:v5Scripts | Should -Not -Contain 'temp-disk-setup.sh'
    }

    It 'the storage reading is taken before the move, so the check after it has a before' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:V5Plan) -RunPath $rp -RunId 'v5-test'
            New-VmfStateDoc -RunPath $rp -RunId 'v5-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:V5Nics $true) } }
            Invoke-VmfStepGuestPrep -Context $ctx | Out-Null
            (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.storageBefore | Should -Not -BeNullOrEmpty
        }
    }

    It 'Intel D v5, off before: NEEDS_DECISION before anything is stopped' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:V5Plan) -RunPath $rp -RunId 'v5-test'
            New-VmfStateDoc -RunPath $rp -RunId 'v5-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:V5Nics $false) } }
            $r = Invoke-VmfStepGuestPrep -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'acceleratedNetworkingRequired'
        }
    }

    It 'Windows losing its temporary disk on v5: the page file is moved; no NVMe script runs' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $p = Global:V5Plan -Size 'Standard_D2s_v5' -Os 'Windows' -TargetArch 'diskless' -Path 'B'
            $ctx = New-VmfContext -PlanEntry $p -RunPath $rp -RunId 'v5-test'
            New-VmfStateDoc -RunPath $rp -RunId 'v5-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:V5Nics $true) } }
            (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED'
        }
        $global:v5Scripts | Should -Contain 'Move-Pagefile.ps1'
        # TEMPCHECK-FIRST-1: the files are asked about in PRECHECK, not here.
        $global:v5Scripts | Should -Not -Contain 'Test-TempDiskContent.ps1'
        $global:v5Scripts | Should -Not -Contain 'Set-NvmeReady.ps1'
        $global:v5Scripts | Should -Not -Contain 'Install-TempDiskInit.ps1'
    }

    It 'Windows keeping its temporary disk on v5: the page file stays where it is' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:V5Plan -Os 'Windows') -RunPath $rp -RunId 'v5-test'
            New-VmfStateDoc -RunPath $rp -RunId 'v5-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:V5Nics $true) } }
            Invoke-VmfStepGuestPrep -Context $ctx | Out-Null
        }
        $global:v5Scripts | Should -Not -Contain 'Move-Pagefile.ps1'
    }

    It 'a SCSI reversion is unchanged: no preparation at all' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:V5Plan -Size 'Standard_D2ds_v6') -RunPath $rp -RunId 'v5-test'
            New-VmfStateDoc -RunPath $rp -RunId 'v5-test' -VmId $ctx.VmId | Out-Null
            (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED'
            # OLD-STATE-READERS-FINISH-1: it saves the decision CONVERTING reads.
            $an = (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.acceleratedNetworking
            [string]$an.policy | Should -Be (Get-VmfPolicy -PlanEntry $ctx.Plan -Name 'acceleratedNetworking')
            $an.expectFabric | Should -BeFalse
        }
        $global:v5Scripts.Count | Should -Be 0
    }
}

Describe 'GEN-V5-1 C4: the conversion step on a v5 move' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-v5c-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'v5c' | Out-Null }
        $global:v5Calls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { $global:v5Calls.Add("patch:$ControllerTypes") }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:v5Calls.Add("resize:$Size/[$Controller]") }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $global:v5Calls.Add("an:$Enabled") }
        Mock -ModuleName VmMigrationFactory Get-VmfClaimForEntry { $null }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
        Remove-Variable v5Calls -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Path <Path>: no disk controller patch, and no controller named for the resize' -ForEach @(
        # REBUILD-REMOVE-ENGINE-1: Moving has no Path B step.
        @{ Path = 'A' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; path = $Path } {
            $planHere = (Global:V5Plan -Path $path)
            $ctx = New-VmfContext -PlanEntry $planHere -RunPath $rp -RunId 'v5c'
            New-VmfStateDoc -RunPath $rp -RunId 'v5c' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ name = 'v5vm'; nics = (Global:V5Nics $true)
                    osDisk = @{ name = 'v5vm-os'; managedDiskId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/v5vm-os' } } }
            Set-VmfTestAnDecision -RunPath $rp -VmId ([string]$planHere.vmId) -PlanEntry $planHere
            Invoke-VmfStepConverting -Context $ctx | Out-Null
        }
        @($global:v5Calls | Where-Object { $_ -like 'patch:*' }).Count | Should -Be 0
        @($global:v5Calls | Where-Object { $_ -like 'resize:*' -or $_ -like 'recreate:*' }) | Should -Be @($(if ($Path -eq 'A') { 'resize:Standard_D2ds_v5/[]' } else { 'recreate:Standard_D2ds_v5/[]' }))
    }

    It 'an NVMe conversion still patches the disk and names NVMe' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $planHere = (Global:V5Plan -Size 'Standard_D2ds_v6' -Controller 'NVMe')
            $ctx = New-VmfContext -PlanEntry $planHere -RunPath $rp -RunId 'v5c'
            New-VmfStateDoc -RunPath $rp -RunId 'v5c' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ name = 'v5vm'; nics = (Global:V5Nics $true)
                    osDisk = @{ name = 'v5vm-os'; managedDiskId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/v5vm-os' } } }
            Set-VmfTestAnDecision -RunPath $rp -VmId ([string]$planHere.vmId) -PlanEntry $planHere
            Invoke-VmfStepConverting -Context $ctx | Out-Null
        }
        $global:v5Calls | Should -Contain 'patch:SCSI, NVMe'
        $global:v5Calls | Should -Contain 'resize:Standard_D2ds_v6/[NVMe]'
    }

    It 'the accelerated networking change comes BEFORE the resize - Microsoft''s order for a series that requires it' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $planHere = (Global:V5Plan -An 'ensureOn')
            $ctx = New-VmfContext -PlanEntry $planHere -RunPath $rp -RunId 'v5c'
            New-VmfStateDoc -RunPath $rp -RunId 'v5c' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ name = 'v5vm'; nics = (Global:V5Nics $false)
                    osDisk = @{ name = 'v5vm-os'; managedDiskId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/v5vm-os' } } }
            Set-VmfTestAnDecision -RunPath $rp -VmId ([string]$planHere.vmId) -PlanEntry $planHere
            Invoke-VmfStepConverting -Context $ctx | Out-Null
        }
        $an = $global:v5Calls.IndexOf('an:True')
        $resize = $global:v5Calls.IndexOf('resize:Standard_D2ds_v5/[]')
        $an | Should -BeGreaterOrEqual 0
        $an | Should -BeLessThan $resize
    }
}

Describe 'GEN-V5-1 C4/C5: the checks around the move' {

    It 'the check after the move looks for an accelerated adapter wherever the decision expects one, not only on NVMe' {
        $sm = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $validating = [regex]::Match($sm, '(?s)function Invoke-VmfStepValidating.*?\n\}').Value
        $validating | Should -Match 'if \(\$anDecision\.ExpectFabric\)'
        $validating | Should -Not -Match "controller -eq 'NVMe' -and \`$anDecision\.ExpectFabric"
    }

    It 'the precheck asks about Azure Disk Encryption for an NVMe move and for the in-place upgrade (Preview)' {
        # v5 keeps Azure Disk Encryption, so a v5 resize (Path A) goes ahead.
        # REBUILD-REMOVE-ENGINE-1: no move rebuilds, so a rebuild is no longer a reason
        # to ask; the Preview, which nobody measured with encryption, is.
        $sm = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $precheck = [regex]::Match($sm, '(?s)function Invoke-VmfStepPrecheck.*?\n\}').Value
        $precheck | Should -Match "controller -eq 'NVMe' -or \(Get-VmfEntryMethod -Entry \`$plan\) -eq 'preview'"
        $precheck | Should -Not -Match "path -eq 'B'"
    }
}
