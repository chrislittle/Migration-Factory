#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# READY-NOW-REMOVE-1: the scan no longer gives the result ReadyNow.
#
# ReadyNow ("Already on a target size", "Already migrated") went to any
# machine whose disk controller was NVMe. After ALREADY-CURRENT-1 a machine on
# a size in the Current lifecycle stage shows Current first, so the only
# machines left with it were the v5 sizes with NVMe: Ebsv5 and Ebdsv5, which
# are in the Extended stage, and whose successor Microsoft lists as Ebsv6. The
# target options refused v6 and v7 for them (already-on-nvme), so they read as
# machines with nothing left to do. The rule since 2026-11-06: such a machine is
# assessed like any other machine - Can migrate when a target exists, else
# Cannot yet with its reason.
#
# What the engine does with it, read 2026-11-06 and held here:
#   - Get-VmfMoveKind gives nvme-conversion for a v6 or v7 target, from the
#     TARGET controller. That stays right for everything it decides: the MANA
#     expectation, the accelerated networking rule and the kernel question are
#     about the target size, which is the same for a source on NVMe.
#   - CONVERTING resizes with the controller NVMe, which the machine already
#     has; a rollback resizes back with the captured controller (NVMe).
#   - GUEST_PREP prepared the guest for SCSI to NVMe (Set-NvmeReady.ps1,
#     nvme-fix.sh). A machine that already runs on NVMe does not need that,
#     and nvme-fix.sh rebuilds the initramfs: it no longer runs for one. The
#     storage reading, the page file and the temporary disk task still do.
#
# tests/fixtures/ready-now-remove.json holds the cases; the page side is
# tests/js/ready-now-remove.test.js.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'ready-now-remove.json') -Raw | ConvertFrom-Json -Depth 20
    $script:schemaFile = Join-Path $script:repoRoot 'schemas' 'assessment.schema.json'

    # A machine in the shape the scan reads from Resource Graph, on a
    # supported Marketplace image.
    function Global:RnScan($Case) {
        $img = if ($Case.os -eq 'Windows') {
            @{ p = 'MicrosoftWindowsServer'; o = 'WindowsServer'; s = '2022-datacenter-smalldisk-g2'; n = 'Windows Server 2022 Datacenter' }
        } else { @{ p = 'Canonical'; o = '0001-com-ubuntu-server-jammy'; s = '22_04-lts-gen2'; n = 'Ubuntu' } }
        $vm = [pscustomobject]@{
            id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/rn'
            name = 'rn'; resourceGroup = 'rg'; location = 'centralus'
            sku = [string]$Case.sourceSize; os = [string]$Case.os; gen = 'V2'; diskController = [string]$Case.diskController
            osName = $img.n; osVersionRunning = '22.04'
            imagePublisher = $img.p; imageOffer = $img.o; imageSku = $img.s
            osDiskManagedId = '/s/rg/disks/rn'; nicCount = 1; nicIds = @()
        }
        InModuleScope VmMigrationFactory -Parameters @{ v = $vm } { Get-VmfAssessmentRecord -Vm $v }
    }
    # The record the plan reads: the scan's, or the one an older assessment holds.
    function Global:RnRecord($Case) {
        if ($Case.stored) {
            return [pscustomobject]@{ classification = [string]$Case.stored; os = [string]$Case.os; gen = 'V2'
                sourceSize = [string]$Case.sourceSize; diskController = [string]$Case.diskController
                sourceDiskArch = [string]$Case.sourceDiskArch; platformManaged = $false; blockers = @(); prepNeeded = @() }
        }
        RnScan $Case
    }
}
AfterAll { Remove-Item 'function:\RnScan', 'function:\RnRecord' -ErrorAction SilentlyContinue }

Describe 'READY-NOW-REMOVE-1: the scan gives no machine ReadyNow' {

    It 'the fixture holds the Ebsv5 and Ebdsv5 shapes on NVMe, Windows and Linux, and no ReadyNow' {
        $nvme = @($script:fixture.cases | Where-Object { $_.diskController -eq 'NVMe' -and -not $_.stored })
        @($nvme | Where-Object { $_.sourceSize -like '*_E*bs_v5' }).Count | Should -BeGreaterThan 0
        @($nvme | Where-Object { $_.sourceSize -like '*_E*bds_v5' -and $_.os -eq 'Windows' }).Count | Should -BeGreaterThan 0
        @($nvme | Where-Object { $_.sourceSize -like '*_E*bds_v5' -and $_.os -eq 'Linux' }).Count | Should -BeGreaterThan 0
        @($script:fixture.cases | Where-Object { $_.stored -eq 'ReadyNow' }).Count | Should -Be 0 -Because 'OLD-VERSION-READERS-REMOVE-2: no reader takes ReadyNow'
    }

    It 'the stage in each case is the stage the lifecycle data gives: <name>' -ForEach @(
        (Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'ready-now-remove.json') -Raw | ConvertFrom-Json -Depth 20).cases |
            ForEach-Object { @{ name = $_.name; size = $_.sourceSize; stage = $_.stage } }) {
        $s = InModuleScope VmMigrationFactory -Parameters @{ n = $size } { Get-VmfSizeLifecycleStage -SizeName $n }
        if ($null -eq $stage) { $s | Should -BeNullOrEmpty } else { $s.Stage | Should -BeExactly $stage }
    }

    It 'writes the classification and the NVMe preparation: <name>' -ForEach @(
        (Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'ready-now-remove.json') -Raw | ConvertFrom-Json -Depth 20).cases |
            Where-Object { -not $_.stored } | ForEach-Object { @{ name = $_.name; c = $_ } }) {
        $r = RnScan $c
        $r.classification | Should -BeExactly $c.scan
        @(@($r.prepNeeded) | Where-Object { $_ -in @('stornvme', 'linux-nvme-prep') }) | Should -Be @($c.nvmePrep)
        $r.sourceDiskArch | Should -BeExactly $c.sourceDiskArch
    }

    It 'Rules.ps1 assigns three classifications, and ReadyNow is not one of them' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Rules.ps1')
        $code | Should -Not -Match "'ReadyNow'"
    }
}

Describe 'READY-NOW-REMOVE-1: the plan reads an older ReadyNow, and finds a path for a machine on NVMe that is not Current' {

    It 'reads the classification for v6: <name>' -ForEach @(
        (Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'ready-now-remove.json') -Raw | ConvertFrom-Json -Depth 20).cases |
            ForEach-Object { @{ name = $_.name; c = $_ } }) {
        $rec = RnRecord $c
        $got = InModuleScope VmMigrationFactory -Parameters @{ a = $rec } { (Resolve-VmfEntryClassification -Assessment $a -TargetGeneration 'v6').Classification }
        $got | Should -BeExactly $c.readAs
    }

    It 'a machine the scan blocked, for reasons that do not apply to the series, is ReadyAfterPrep on NVMe too' {
        $a = [pscustomobject]@{ classification = 'Blocked'; diskController = 'NVMe'; blockers = @('gen1-requires-redeploy'); prepNeeded = @() }
        InModuleScope VmMigrationFactory -Parameters @{ a = $a } {
            (Resolve-VmfEntryClassification -Assessment $a -TargetGeneration 'v5').Classification | Should -BeExactly 'ReadyAfterPrep'
        }
    }

    It 'finds a path to v6 and v7 only where the case says: <name>' -ForEach @(
        (Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'ready-now-remove.json') -Raw | ConvertFrom-Json -Depth 20).cases |
            ForEach-Object { @{ name = $_.name; c = $_ } }) {
        $rec = RnRecord $c
        foreach ($g in 'v6', 'v7') {
            $want = if ($g -eq 'v6') { [bool]$c.openV6 } else { [bool]$c.openV7 }
            $path = InModuleScope VmMigrationFactory -Parameters @{ a = $rec; t = [string]$c.targetDiskArch; g = $g } {
                Get-VmfPathSelection -Assessment $a -TargetDiskArch $t -TargetGeneration $g }
            ($path -ne 'EXCLUDED') | Should -Be $want -Because "$g gave '$path'"
        }
    }

    It 'a machine on NVMe on v5 is still already on its series: no v5 move' {
        $rec = RnScan ($script:fixture.cases | Where-Object { $_.sourceSize -eq 'Standard_E2bs_v5' -and $_.diskController -eq 'NVMe' -and -not $_.stored } | Select-Object -First 1)
        InModuleScope VmMigrationFactory -Parameters @{ a = $rec } {
            Get-VmfPathSelection -Assessment $a -TargetDiskArch 'diskless' -TargetGeneration 'v5' | Should -BeExactly 'EXCLUDED'
        }
    }

    It 'the stage comes from the lifecycle data, never from the size name' {
        $a = [pscustomobject]@{ classification = 'ReadyAfterPrep'; os = 'Linux'; sourceSize = 'Standard_E2bs_v5'; diskController = 'NVMe'; sourceDiskArch = 'diskless'; platformManaged = $false }
        Mock -ModuleName VmMigrationFactory Get-VmfSizeLifecycleStage { @{ Stage = 'Current'; Basis = 'stated'; Source = 'x'; How = '' } }
        InModuleScope VmMigrationFactory -Parameters @{ a = $a } {
            Get-VmfPathSelection -Assessment $a -TargetDiskArch 'diskless' -TargetGeneration 'v6' | Should -BeExactly 'EXCLUDED'
        }
    }
}

Describe 'READY-NOW-REMOVE-1: the target options offer Ebsv6 to a machine on Ebsv5 with NVMe' {
    BeforeAll {
        function Global:RnSku([string]$Name, [string]$TempMb = '0') {
            [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
                Capabilities = @(
                    [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                    [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                    [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                    [pscustomobject]@{ Name = 'AcceleratedNetworkingEnabled'; Value = 'True' }
                    [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V2' }) }
        }
        $script:rnCatalog = @{}
        foreach ($s in @((RnSku 'Standard_E2bs_v5'), (RnSku 'Standard_E2bds_v5' '76800'), (RnSku 'Standard_E2bs_v6'), (RnSku 'Standard_E2bds_v6'),
                (RnSku 'Standard_D2ds_v6'), (RnSku 'Standard_D2ds_v7'))) { $script:rnCatalog[$s.Name] = $s }
        $script:rnAdvise = {
            param($Vm)
            $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-rn'; vms = @($Vm) }
            InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = $script:rnCatalog } } {
                @((Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c -RegionsNotRead @()).machines)[0]
            }
        }
        $script:rnVm = {
            param([string]$Size, [string]$Arch, [string]$Classification = 'ReadyAfterPrep')
            [pscustomobject]@{
                vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/rn'
                name = 'rn'; location = 'centralus'; classification = $Classification; gen = 'V2'; os = 'Linux'; osVersion = '22_04-lts-gen2'
                runningOsName = 'Ubuntu'; runningOsVersion = '22.04'
                sourceSize = $Size; sourceDiskArch = $Arch; sourceTempDisks = $(if ($Arch -eq 'scsi-temp') { 1 } else { 0 })
                diskController = 'NVMe'; dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
                platformManaged = $false; blockers = @(); prepNeeded = @()
            }
        }
    }
    AfterAll { Remove-Item 'function:\RnSku' -ErrorAction SilentlyContinue }

    It 'Ebsv5 on NVMe: v6 is supported, on Ebsv6, as the move to NVMe; v5 is the series it is on' {
        $m = & $script:rnAdvise (& $script:rnVm 'Standard_E2bs_v5' 'diskless')
        $v6 = @($m.options) | Where-Object { $_.option -eq 'v6' }
        @($v6.notSupported) | Should -Not -Contain 'already-on-nvme'
        $v6.supported | Should -BeTrue -Because "it said $(@($v6.notSupported) -join ', ')"
        $v6.targetSize | Should -BeExactly 'Standard_E2bs_v6'
        $v6.move | Should -BeExactly 'nvme-conversion'
        @((@($m.options) | Where-Object { $_.option -eq 'v5' }).notSupported) | Should -Be @('already-on-series')
        $m.start.current | Should -BeExactly 'v6'
    }


    It 'a machine on a Current size on NVMe keeps already-on-nvme on v6 and v7' {
        $m = & $script:rnAdvise (& $script:rnVm 'Standard_D2ds_v6' 'nvme-temp')
        @((@($m.options) | Where-Object { $_.option -eq 'v6' }).notSupported) | Should -Be @('already-on-nvme')
        @((@($m.options) | Where-Object { $_.option -eq 'v7' }).notSupported) | Should -Be @('already-on-nvme')
    }
}

Describe 'READY-NOW-REMOVE-1: GUEST_PREP and STOPPED on a machine that already runs on NVMe' {
    # Review round 1: the first version skipped Set-NvmeReady.ps1 and
    # nvme-fix.sh for a machine already on NVMe. Both are idempotent, and both
    # are needed: nvme-fix.sh sets nvme_core.io_timeout and the fstab by UUID,
    # which a machine created on NVMe can lack, and the STOPPED guard reads
    # Test-NvmeReady.ps1 for every NVMe target - with the fix skipped, a guest
    # that lacks the stornvme values went back to GUEST_PREP on every pass.
    BeforeAll {
        Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
        $script:rnPlan = {
            param([string]$Os, [string]$Controller, [string]$SourceArch = 'diskless', [string]$TargetArch = 'diskless')
            [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/rnvm'
                wave = 'w1'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os; diskController = $Controller
                    sourceSize = 'Standard_E2bs_v5'; sourceDiskArch = $SourceArch; platformManaged = $false }
                target = [pscustomobject]@{ size = 'Standard_E2bs_v6'; diskArch = $TargetArch; controller = 'NVMe' }
                path = 'A'
                policy = [pscustomobject]@{ onDriverBelowFloor = 'stop'; onDDataFound = 'stop' }
            }
        }
        # Runs the named steps in order on one machine; the capture holds the
        # controller Azure reports at Checking.
        $script:rnStep = {
            param($Plan, [string[]]$Steps)
            $rp = $script:rnRun
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; p = $Plan; st = $Steps } {
                $ctx = New-VmfContext -PlanEntry $p -RunPath $rp -RunId 'rn-test'
                New-VmfStateDoc -RunPath $rp -RunId 'rn-test' -VmId $ctx.VmId | Out-Null
                $nics = @([pscustomobject]@{ id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic0'; primary = $true; acceleratedNetworking = $true })
                Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = $nics; controller = $p.assessment.diskController } }
                foreach ($s in $st) {
                    if ($s -eq 'GUEST_PREP') { Invoke-VmfStepGuestPrep -Context $ctx } else { Invoke-VmfStepStopped -Context $ctx }
                }
            }
        }
    }
    BeforeEach {
        $script:rnRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rn-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rnRun } { Initialize-VmfRun -RunPath $rp -RunId 'rn-test' | Out-Null }
        $global:rnScripts = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:rnScripts.Add('deallocate') }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            $global:rnScripts.Add($ScriptName)
            if ($ScriptName -eq 'Install-ManaDriver.ps1') { return [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1'; result = 'NO_CHANGE'; warnings = @(); checks = @() } }
            # A guest created on NVMe that lacks the stornvme values the
            # product writes: NEEDS_PREP until Set-NvmeReady.ps1 has run.
            $result = if ($ScriptName -eq 'Test-NvmeReady.ps1' -and $global:rnScripts -notcontains 'Set-NvmeReady.ps1') { 'NEEDS_PREP' } else { 'READY' }
            $facts = [pscustomobject]@{ os = 'Linux'; kernelVersion = '5.15.0-1100-azure'; distroId = 'ubuntu'; distroVersion = '22.04'; fabric = 'mlx' }
            [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1'; os = 'x'; result = $result; warnings = @()
                checks = @([pscustomobject]@{ name = 'mana module available'; status = 'PASS'; detail = 'modinfo mana' }); facts = $facts }
        }
    }
    AfterEach {
        if (Test-Path $script:rnRun) { Remove-Item $script:rnRun -Recurse -Force }
        Remove-Variable rnScripts -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Windows on NVMe: GUEST_PREP prepares the guest, and STOPPED then deallocates - no loop back to GUEST_PREP' {
        $r = @(& $script:rnStep (& $script:rnPlan 'Windows' 'NVMe') @('GUEST_PREP', 'STOPPED'))
        $r[0].Next | Should -Be 'STOPPED'
        $r[1].Next | Should -Be 'SAFETY_COPY' -Because "STOPPED said: $($r[1].Detail)"
        $global:rnScripts | Should -Contain 'Set-NvmeReady.ps1'
        $global:rnScripts | Should -Contain 'deallocate'
    }

    It 'Linux on NVMe: nvme-fix.sh runs, for the I/O timeout and the fstab by UUID' {
        (@(& $script:rnStep (& $script:rnPlan 'Linux' 'NVMe') @('GUEST_PREP')))[0].Next | Should -Be 'STOPPED'
        $global:rnScripts | Should -Contain 'nvme-check.sh'
        $global:rnScripts | Should -Contain 'nvme-fix.sh'
    }

    It 'Windows on NVMe, leaving a SCSI temporary disk for an NVMe one: the page file and the temporary disk task run too' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfPagefileMove { $global:rnScripts.Add('pagefile'); $null }
        (@(& $script:rnStep (& $script:rnPlan 'Windows' 'NVMe' 'scsi-temp' 'nvme-temp') @('GUEST_PREP')))[0].Next | Should -Be 'STOPPED'
        $global:rnScripts | Should -Contain 'Set-NvmeReady.ps1'
        $global:rnScripts | Should -Contain 'pagefile'
        $global:rnScripts | Should -Contain 'Install-TempDiskInit.ps1'
    }

    It 'the move kind stays nvme-conversion: the target decides the network and the kernel' {
        InModuleScope VmMigrationFactory -Parameters @{ p = (& $script:rnPlan 'Linux' 'NVMe') } {
            Get-VmfMoveKind -PlanEntry $p | Should -BeExactly 'nvme-conversion'
        }
    }
}

Describe 'READY-NOW-REMOVE-1 (review), MANUAL-REVIEW-1: the plan writes no note about a lab run' {

    It 'no function writes the note that no lab run has moved such a machine' {
        InModuleScope VmMigrationFactory { Get-Command Get-VmfNvmeSourceNote -ErrorAction SilentlyContinue | Should -BeNullOrEmpty }
        Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'PlanNotes.ps1') |
            Should -Not -Match '(?i)\blab\b'
    }

    It 'New-VmfPlan writes planNotes, and the classification as the scan gave it' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfPlan.ps1')
        # PLAN-NOTES-TARGET-1: through the one function both plan writers ask.
        $code | Should -Match 'Get-VmfPlanEntryNotes -Mapping \$p\.mapping -Assessment \$p\.vm -Controller \(\[string\]\$p\.controller\) -Path \(\[string\]\$p\.path\)'
        $code | Should -Match 'classification = \[string\]\$p\.vm\.classification'
    }
}

Describe 'READY-NOW-REMOVE-1: the assessment contract is version 11' {

    It 'the version is 11, and a v11 assessment holds no ReadyNow, in a record or in the summary' {
        InModuleScope VmMigrationFactory { Get-VmfAssessmentSchemaVersion | Should -Be 17 }
        $rec = [ordered]@{ vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/a'; name = 'a'
            resourceGroup = 'rg'; location = 'centralus'; classification = 'ReadyAfterPrep'; sourceSize = 'Standard_E2bs_v5' }
        $doc = [ordered]@{ schemaVersion = 17; runId = 'r'; generatedUtc = '2026-11-06T00:00:00Z'; scope = [ordered]@{ subscriptions = @() }
            summary = [ordered]@{ ReadyAfterPrep = 1 }; vms = @($rec) }
        Test-Json -Json ($doc | ConvertTo-Json -Depth 8) -SchemaFile $script:schemaFile -ErrorAction Stop | Should -BeTrue
        $rec.classification = 'ReadyNow'
        Test-Json -Json ($doc | ConvertTo-Json -Depth 8) -SchemaFile $script:schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
        $rec.classification = 'ReadyAfterPrep'
        $doc.summary = [ordered]@{ ReadyNow = 1 }
        Test-Json -Json ($doc | ConvertTo-Json -Depth 8) -SchemaFile $script:schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'a v10 assessment that holds ReadyNow is not valid, and not read (OLD-VERSION-READERS-REMOVE-1)' {
        $doc = [ordered]@{ schemaVersion = 10; runId = 'r'; generatedUtc = '2026-11-06T00:00:00Z'; scope = [ordered]@{ subscriptions = @() }
            summary = [ordered]@{ ReadyNow = 1 }
            vms = @([ordered]@{ vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/a'; name = 'a'
                    resourceGroup = 'rg'; location = 'centralus'; classification = 'ReadyNow'; sourceSize = 'Standard_E2bs_v5' }) }
        Test-Json -Json ($doc | ConvertTo-Json -Depth 8) -SchemaFile $script:schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
        InModuleScope VmMigrationFactory -Parameters @{ d = [pscustomobject]$doc } { { Assert-VmfSupportedAssessment -Assessment $d } | Should -Throw '*reads only version 17*' }
    }

    It 'the report has no tone of its own for ReadyNow' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfReport.ps1')
        $code | Should -Not -Match 'ReadyNow'
    }
}
