#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# BSV2-NOTES-1: three records that did not match what a Bsv2 move did.
#
# The in-app lab run of 2026-10-11 (docs/evidence/lab-2026-10-11-in-app.md)
# moved mx-b2s (Linux, B2s -> B2ls_v2, in place) and mx-b2w (Windows
# Generation 1, B2ms -> B2s_v2, a Path B rebuild). Both moves turned
# accelerated networking on (policy ensureOn), and three records said other
# things:
#   1. the target advice said acceleratedNetworking.turnsOn false for both.
#      The advice answered "turns on" only for a size that REQUIRES it, while
#      the engine turns the primary interface on for every move but a SCSI
#      reversion (Get-VmfPolicy) - except a Linux kernel with no MANA driver
#      on a size that can give MANA (AN-KEEP-1). The targets step painted
#      "Off -> Off" from it;
#   2. GUEST_PREP said "v5 resize - no NVMe preparation." for the rebuild;
#   3. both plan entries held sizeAlternates [""].

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:BnEntries([string]$File) {
        $doc = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' $File) -Raw | ConvertFrom-Json
        foreach ($s in @($doc.sizes)) {
            $caps = @(foreach ($c in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $c.Name; Value = [string]$c.Value } })
            [pscustomobject]@{
                Name = $s.name; ResourceType = 'virtualMachines'; Capabilities = $caps
                Family = $(if ($s.PSObject.Properties['family']) { [string]$s.family } else { 'standardX' })
                Restrictions = @(); LocationInfo = @([pscustomobject]@{ Location = 'centralus'; Zones = @($s.zones) })
            }
        }
    }
    $script:bnCatalog = @{}
    foreach ($e in @(BnEntries 'old-size-catalog-centralus.json') + @(BnEntries 'bsv2-catalog-centralus.json')) { $script:bnCatalog[$e.Name] = $e }

    # -Release: the release the VM agent reports ('' for none).
    function Global:BnVm {
        param([string]$Size = 'Standard_B2s', [string]$Gen = 'V2', [string]$Os = 'Linux', [object]$Primary = $false,
              [string]$Release = '22.04', [string]$Name = 'bn-01')
        $tempMb = [int](@($script:bnCatalog[$Size].Capabilities | Where-Object { $_.Name -eq 'MaxResourceVolumeMB' })[0].Value)
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @(); gen = $Gen
            os = $Os; osVersion = $(if ($Os -eq 'Windows') { '2019-datacenter' } else { 'custom' })
            runningOsName = $(if ($Os -eq 'Linux' -and $Release) { 'ubuntu' } else { '' })
            runningOsVersion = $(if ($Os -eq 'Linux') { $Release } else { '' })
            classification = 'ReadyAfterPrep'; blockers = @(if ($Gen -eq 'V1') { 'gen1-requires-redeploy' }); prepNeeded = @()
            sourceSize = $Size; sourceDiskArch = $(if ($tempMb -gt 0) { 'scsi-temp' } else { 'diskless' }); sourceTempDisks = $(if ($tempMb -gt 0) { 1 } else { 0 })
            diskController = $(if ($Gen -eq 'V1') { '' } else { 'SCSI' }); dataDiskCount = 1; nicCount = 1
            acceleratedNicCount = $(if ($null -eq $Primary) { $null } elseif ($Primary) { 1 } else { 0 })
            primaryNicAccelerated = $Primary; platformManaged = $false; iacManaged = $false
            hibernationEnabled = $false; availabilitySetId = ''; identityType = 'None'; tags = @{ app = $Name }
        }
    }
    function Global:BnOption($Vm, [string]$Series = 'v5') {
        $doc = [pscustomobject]@{ runId = 'scan-bn'; vms = @($Vm) }
        $a = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = $script:bnCatalog } } {
            param($d, $c) Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
        @(@($a.machines)[0].options | Where-Object { $_.option -eq $Series })[0]
    }
}
AfterAll {
    Remove-Item 'function:\BnEntries', 'function:\BnVm', 'function:\BnOption' -ErrorAction SilentlyContinue
}

Describe 'BSV2-NOTES-1 (1): the target advice says the move turns accelerated networking on, as the engine does' {

    # Review, 2026-10-23 said unknown here: the engine kept the primary off for
    # a kernel with no MANA driver (AN-KEEP-1). AN-MANA-DRIVER-RULE-1 (owner,
    # 2026-11-06) rewrote it: no size keeps it off now, so the move turns it on
    # (or stops in Preparing, untouched, for a kernel with no driver).
    It 'B2s -> B2ls_v2, Linux whose release Microsoft lists, the primary off: it turns on; Bsv2 does not require it' {
        $o = BnOption (BnVm -Size 'Standard_B2s')
        $o.targetSize | Should -Be 'Standard_B2ls_v2'
        $o.acceleratedNetworking.required | Should -BeFalse
        $o.acceleratedNetworking.turnsOn | Should -BeTrue
        @($o.stops) | Should -Not -Contain 'acceleratedNetworkingRequired' -Because 'only a size that requires it stops for an approver'
    }

    # REBUILD-REMOVE-PLAN-1: the in-place upgrade (Preview), no longer a rebuild.
    It 'B2ms -> B2s_v2, Windows Generation 1, the primary off: it turns on (the in-place upgrade (Preview))' {
        $o = BnOption (BnVm -Size 'Standard_B2ms' -Gen 'V1' -Os 'Windows')
        $o.targetSize | Should -Be 'Standard_B2s_v2'
        $o.path | Should -Be 'A'
        $o.preview | Should -BeTrue
        $o.acceleratedNetworking.turnsOn | Should -BeTrue
        @($o.stops).Count | Should -Be 0
    }

    It 'the primary on already: nothing turns on' {
        (BnOption (BnVm -Primary $true)).acceleratedNetworking.turnsOn | Should -BeFalse
    }

    # AN-NAMES-KERNEL-1 (review of WAVE-AN-NAMES-1) rewrote this test: it said
    # "it stays off". GUEST_PREP reads a kernel of 6.14 or later on such a
    # release as a MANA driver (Get-VmfManaDriverPresence), and the move turns
    # the primary on. The advice cannot read the kernel, so it is unknown.
    # AN-MANA-DRIVER-RULE-1: rewritten. Such a release is offered no size that
    # can give MANA - Bsv2 included - so there is nothing to turn on.
    It 'a Linux release Microsoft does not list, read from the VM agent: no size that can give MANA is offered' {
        foreach ($s in 'v5', 'v6', 'v7') {
            @((BnOption (BnVm -Release '18.04') $s).notSupported) | Should -Contain 'no-mana-driver' -Because $s
        }
    }

    It 'a Linux release nobody read, on a size that can give MANA: it turns on, and the run reads the driver' {
        (BnOption (BnVm -Release '')).acceleratedNetworking.turnsOn | Should -BeTrue
    }

    It 'the primary not read: unknown, never a no' {
        $null -eq (BnOption (BnVm -Primary $null)).acceleratedNetworking.turnsOn | Should -BeTrue
    }

    It 'a size choice that requires it (Intel D v5) turns it on and keeps its stop' {
        $o = BnOption (BnVm -Size 'Standard_B2s')
        $d = @($o.sizeChoices | Where-Object { [string]$_.size -match '^Standard_D\d+[a-z]*_v5$' -and $_.acceleratedNetworking.required -eq $true })[0]
        $d | Should -Not -BeNullOrEmpty
        $d.acceleratedNetworking.turnsOn | Should -BeTrue
        @($d.stops) | Should -Contain 'acceleratedNetworkingRequired'
    }

    It 'the rule itself: <Why>' -ForEach @(
        @{ Why = 'a SCSI reversion keeps it as it was (preserve)'; Move = 'scsi-reversion'; Os = 'Windows'; Release = ''; Required = $false; Listing = ''; Want = $false }
        @{ Why = 'a size that requires it turns it on, before the MANA question'; Move = 'nvme-conversion'; Os = 'Linux'; Release = '18.04'; Required = $true; Listing = 'unlisted'; Want = $true }
        @{ Why = 'an operating system that is neither Windows nor Linux turns on (AN-MANA-DRIVER-RULE-1)'; Move = 'nvme-conversion'; Os = ''; Release = ''; Required = $false; Listing = 'listed'; Want = $true }
        @{ Why = 'Windows turns on where MANA is possible'; Move = 'nvme-conversion'; Os = 'Windows'; Release = ''; Required = $false; Listing = ''; Want = $true }
        @{ Why = 'a Linux release Microsoft lists turns on where MANA is possible (AN-MANA-DRIVER-RULE-1)'; Move = 'nvme-conversion'; Os = 'Linux'; Release = '22.04'; Required = $false; Listing = 'listed'; Want = $true }
        @{ Why = 'Linux turns on where the size never gives MANA (AMD v5)'; Move = 'scsi-resize'; Os = 'Linux'; Release = ''; Required = $false; Listing = ''; Want = $true; Size = 'Standard_D2as_v5' }
    ) {
        $vm = BnVm -Os $(if ($Os) { $Os } else { 'Linux' }) -Release $Release
        if (-not $Os) { $vm.os = '' }
        $got = InModuleScope VmMigrationFactory -Parameters @{ vm = $vm; move = $Move; req = $Required; size = $Size } {
            param($vm, $move, $req, $size)
            Get-VmfAnTurnsOn -Vm $vm -TargetSize $(if ($size) { $size } else { 'Standard_D2ds_v6' }) -Move $move -Required $req
        }
        if ($null -eq $Want) { $null -eq $got | Should -BeTrue } else { $got | Should -Be $Want }
    }

    # Each case names every reading GUEST_PREP can make of the driver
    # (Get-VmfManaDriverPresence): a listed release with a kernel that has the
    # module or not; an unlisted release the agent reports; Windows always
    # unknown. Where the readings agree, the advice gives that answer; where
    # they differ, the kernel decides, and the advice says unknown.
    It 'every option and size choice gives the answer the engine gives for that move (Resolve-VmfAcceleratedNetworkingForMove)' {
        $checked = 0
        $unknown = 0
        foreach ($case in @(
                @{ Os = 'Linux'; Release = '22.04'; Gen = 'V2'; Drivers = @('present', 'absent') }
                @{ Os = 'Linux'; Release = '18.04'; Gen = 'V2'; Drivers = @('unlisted', 'present') }
                @{ Os = 'Windows'; Release = ''; Gen = 'V2'; Drivers = @('unknown') }
                @{ Os = 'Windows'; Release = ''; Gen = 'V1'; Drivers = @('unknown') })) {
            foreach ($primary in $false, $true) {
                foreach ($size in 'Standard_B2s', 'Standard_B2ms', 'Standard_D2_v2', 'Standard_E2s_v5') {
                    $vm = BnVm -Size $size -Os $case.Os -Release $case.Release -Gen $case.Gen -Primary $primary
                    foreach ($series in 'v5', 'v6', 'v7') {
                        $o = BnOption $vm $series
                        if (-not $o.supported) { continue }
                        $facts = @([pscustomobject]@{ size = [string]$o.targetSize; an = $o.acceleratedNetworking }) +
                            @(@($o.sizeChoices) | ForEach-Object { [pscustomobject]@{ size = [string]$_.size; an = $_.acceleratedNetworking } })
                        foreach ($f in $facts) {
                            $answers = @(foreach ($drv in $case.Drivers) { InModuleScope VmMigrationFactory -Parameters @{ vm = $vm; size = $f.size; series = $series; on = $primary; drv = $drv } {
                                param($vm, $size, $series, $on, $drv)
                                # The plan's own setting for this machine (AN-PLAN-1), as New-VmfPlan writes it.
                                $planned = Get-VmfPlannedAcceleratedNetworking -Vm $vm -TargetSize $size
                                $entry = [pscustomobject]@{
                                    target = [pscustomobject]@{ size = $size; controller = (Get-VmfGenerationController -Generation $series) }
                                    policy = [pscustomobject]@{ acceleratedNetworking = $planned; onDriverBelowFloor = 'stop' }
                                }
                                $nics = @([pscustomobject]@{ id = 'nic0'; primary = $true; acceleratedNetworking = $on })
                                $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $entry -CapturedNics $nics -ManaDriver $drv
                                # A stop for an approver (driverBelowFloor, acceleratedNetworkingRequired)
                                # leaves the planned setting: a move that goes on turns it on.
                                [bool]($r.OnAfter -and -not $on)
                            } })
                            $because = "$($case.Os) $($case.Release) $($case.Gen), $size -> $($f.size) on $series, primary on: $primary"
                            if (@($answers | Sort-Object -Unique).Count -gt 1) {
                                $null -eq $f.an.turnsOn | Should -BeTrue -Because "$because - the kernel decides"
                                $unknown++
                            }
                            else { $f.an.turnsOn | Should -Be $answers[0] -Because $because }
                            $checked++
                        }
                    }
                }
            }
        }
        $checked | Should -BeGreaterThan 40
        # AN-MANA-DRIVER-RULE-1: the kernel decided only because a missing
        # driver kept the primary off; nothing keeps it off now.
        $unknown | Should -Be 0 -Because 'no move is decided by the kernel any more'
    }
}

Describe 'BSV2-NOTES-1 (3): a plan entry names no empty alternate size' {
    BeforeEach {
        $script:bnRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-bn-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:bnList = @($script:bnCatalog.Values)
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:bnList }
        $vms = @((BnVm -Size 'Standard_B2s' -Name 'b2s'), (BnVm -Size 'Standard_B2ms' -Gen 'V1' -Os 'Windows' -Name 'b2w'))
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $script:bnRun -Leaf); generatedUtc = '2026-10-23T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}; vms = $vms }
        InModuleScope VmMigrationFactory -Parameters @{ r = $script:bnRun; d = $doc } {
            param($r, $d)
            Initialize-VmfRun -RunPath $r -RunId (Split-Path $r -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $r -RelPath 'assessment.json' -Document $d -Depth 24
        }
        Approve-VmfAssessment -RunPath $script:bnRun -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfTargetAdvice -AssessmentPath (Join-Path $script:bnRun 'assessment.json') | Out-Null
        $adviceVersion = InModuleScope VmMigrationFactory -Parameters @{ r = $script:bnRun } {
            param($r) Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $r -RelPath 'target-advice.json')) }
        Set-VmfTestTargetChoice -RunPath $script:bnRun -Default 'current' -ExpectedAdviceVersion $adviceVersion -ExpectedChoicesVersion '' `
            -Choices @($vms | ForEach-Object { @{ vmId = $_.vmId; option = 'v5' } }) -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfPlan -AssessmentPath (Join-Path $script:bnRun 'assessment.json') -OutPath "$script:bnRun-migration" | Out-Null
        $script:bnPlan = Get-Content (Join-Path "$script:bnRun-migration" 'plan.json') -Raw | ConvertFrom-Json -Depth 40
    }
    AfterEach {
        foreach ($d in $script:bnRun, "$script:bnRun-migration") { if ($d -and (Test-Path $d)) { [System.IO.Directory]::Delete($d, $true) } }
    }

    It 'both Bsv2 machines are planned, and neither holds an alternate size - one size was tried' {
        $entries = @($script:bnPlan.entries)
        @($entries | ForEach-Object { [string]$_.target.size } | Sort-Object) | Should -Be @('Standard_B2ls_v2', 'Standard_B2s_v2')
        foreach ($e in $entries) {
            $raw = $e.target.sizeAlternates
            @($raw).Count | Should -Be 0 -Because "$($e.target.size) was planned as a named size, with no other size to try"
        }
    }

    It 'the plan file itself writes an empty list, never a list with an empty name' {
        $text = Get-Content (Join-Path "$script:bnRun-migration" 'plan.json') -Raw
        $text | Should -Not -Match '"sizeAlternates":\s*\[\s*""'
        $text | Should -Not -Match '"sizeAlternates":\s*\[\s*null'
    }
}

Describe 'BSV2-NOTES-1 (2): GUEST_PREP names the move it prepares' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-bnp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'bn-prep' | Out-Null }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            if ($ScriptName -eq 'Install-ManaDriver.ps1') { return [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1'; result = 'NO_CHANGE'; warnings = @(); checks = @() } }
            [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1'; os = 'x'; result = 'READY'; warnings = @()
                checks = @([pscustomobject]@{ name = 'mana module available'; status = 'PASS'; detail = 'modinfo mana' })
                facts = [pscustomobject]@{ os = 'Windows' } }
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It '<Path>: <Want>' -ForEach @(
        @{ Path = 'A'; Size = 'Standard_B2ls_v2'; SourceArch = 'diskless'; Want = 'An in-place upgrade'; Not = '(?i)rebuil|resize' }
    ) {
        $detail = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; path = $Path; size = $Size; arch = $SourceArch } {
            param($rp, $path, $size, $arch)
            $entry = [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion); wave = 'w1'
                vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/bnvm'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V1'; os = 'Windows'; sourceSize = 'Standard_B2ms'
                    sourceDiskArch = $arch; platformManaged = $false }
                target = [pscustomobject]@{ size = $size; diskArch = 'diskless'; controller = 'SCSI' }
                path = $path
                policy = [pscustomobject]@{ onDriverBelowFloor = 'stop'; onDDataFound = 'stop' }
            }
            $ctx = New-VmfContext -PlanEntry $entry -RunPath $rp -RunId 'bn-prep'
            New-VmfStateDoc -RunPath $rp -RunId 'bn-prep' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = @([pscustomobject]@{ id = 'nic0'; primary = $true; acceleratedNetworking = $true }) } }
            $r = Invoke-VmfStepGuestPrep -Context $ctx
            $r.Next | Should -Be 'STOPPED'
            [string]$r.Detail
        }
        $detail | Should -Not -Match 'v5 resize'
        $detail | Should -Match ([regex]::Escape($Want))
        $detail | Should -Not -Match $Not
        $detail | Should -Match ([regex]::Escape($Size))
        $detail | Should -Match 'SCSI'
    }
}

# Lead, 2026-10-23: the targets step said "Resize, rebuilt around the same
# disks" for a Path B move - the same defect as (2). Every place an operator
# reads the kind of move names it by its path, with the names of the manual
# (understand/how-a-machine-moves.md): In-place upgrade, Rebuild around the
# same disks.
Describe 'BSV2-NOTES-1 (2): the move is named by its path, with one name' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:names = InModuleScope VmMigrationFactory { @{ A = (Get-VmfMoveName -Path 'A') } }
    }

    It 'the engine uses the names of the manual' {
        $script:names.A | Should -BeExactly 'In-place upgrade'
        $manual = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'understand' 'how-a-machine-moves.md') -Raw
        $manual | Should -Match ([regex]::Escape("**$($script:names.A).**"))
        # OLD-REBUILD-RESTORE-READERS-1: no name for the rebuild, on the page or here.
        InModuleScope VmMigrationFactory { Get-VmfMoveName -Path 'B' } | Should -BeNullOrEmpty
        $manual | Should -Not -Match 'Rebuild around the same disks'
    }

    It '<Page> names the paths the same way' -ForEach @(
        @{ Page = 'migrations.html'; Pattern = "const UX_PATH = \{ A: '([^']+)' \};" }
        @{ Page = 'reports.html'; Pattern = "const PATH_WORDS = \{ A: '([^']+)' \};" }
        @{ Page = 'assessments.html'; Pattern = "const PATH_WORDS = \{ A: '([^']+)' \};" }
        # REBUILD-REMOVE-PLAN-1: the targets step names no rebuild, so it has kPathA only (below).
    ) {
        $text = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' $Page))
        $m = [regex]::Match($text, $Pattern)
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -BeExactly $script:names.A
    }

    It 'the targets step names the in-place upgrade the same way, and no rebuild' {
        $text = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))
        $m = [regex]::Match($text, "kPathA: '([^']+)',")
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -BeExactly $script:names.A
        $text | Should -Not -Match 'kPathB:'
    }

    It 'the customer report names the paths the same way' {
        $method = InModuleScope VmMigrationFactory { $script:VmfReportMethod }
        $method.A | Should -BeExactly $script:names.A
        $method.ContainsKey('B') | Should -BeFalse
    }
}

Describe 'BSV2-NOTES-1 (2): the run history line after the move names it by its path' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-bnc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'bnc' | Out-Null }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { }
        Mock -ModuleName VmMigrationFactory Get-VmfClaimForEntry { $null }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'Path <Path>: <Want>' -ForEach @(
        @{ Path = 'A'; Want = 'In-place upgrade'; Not = '(?i)rebuil|recreat|Path [AB]' }
        # REBUILD-REMOVE-ENGINE-1: Moving has no Path B step, so no line names one.
    ) {
        $detail = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; path = $Path } {
            param($rp, $path)
            $entry = [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion); wave = 'w1'
                vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/bnvm'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V1'; os = 'Linux'; sourceSize = 'Standard_B2ms'
                    sourceDiskArch = 'diskless'; platformManaged = $false }
                target = [pscustomobject]@{ size = 'Standard_B2s_v2'; diskArch = 'diskless'; controller = 'SCSI' }
                path = $path
                policy = [pscustomobject]@{ onDriverBelowFloor = 'stop'; onDDataFound = 'stop' }
            }
            $ctx = New-VmfContext -PlanEntry $entry -RunPath $rp -RunId 'bnc'
            New-VmfStateDoc -RunPath $rp -RunId 'bnc' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ name = 'bnvm'
                    nics = @([pscustomobject]@{ id = 'nic0'; primary = $true; acceleratedNetworking = $true })
                    osDisk = @{ name = 'bnvm-os'; managedDiskId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/bnvm-os' } } }
            Set-VmfTestAnDecision -RunPath $rp -VmId ([string]$entry.vmId) -PlanEntry $entry
            [string](Invoke-VmfStepConverting -Context $ctx).Detail
        }
        $detail | Should -Match ([regex]::Escape($Want))
        $detail | Should -Match 'Standard_B2s_v2'
        $detail | Should -Not -Match $Not
    }
}
