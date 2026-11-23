#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# RETIRE-SCOPE-1: a machine on a size Microsoft retires is OUTSIDE THE SCOPE
# OF THIS TOOL from one day before the retirement date. It reverses the part of
# V3-RETIRE-1 that gave the rollback the nearest current size.
#
# Decided 2026-10-04: the product does not support a machine that was not
# moved in time by the Microsoft lifecycle; after retirement it is outside the
# scope of this tool. Microsoft: at the retirement date the remaining
# machines are deallocated and stop working; their managed disks are kept, and
# they come back only by a resize to a supported size.
#
# Before the margin nothing changes: the move is allowed, its rollback goes to
# the original size, and the product warns from 12 months before. From one day
# before the date (a rollback started that evening could reach the old size
# after midnight) the assessment says so, the advice gives no option, the plan
# does not plan it, PRECHECK refuses it untouched, and a restore from the first
# copy or a rebuild as it was is refused before anything changes.
#
# The real dates are years away. The module's data is replaced in memory with
# Dv3/Dsv3/Ev3/Esv3 retiring a set number of days from today, and put back
# after each test.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }
    # OLD-VERSION-READERS-REMOVE-4: every disk made from a copy is read back and its key compared, so the fake Azure answers the read.
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    # LINUX-TEMP-DISK-FILES-1: the temporary disk check at Checking, now asked of a Linux
    # machine too, is not under test here; LinuxTempDiskFiles.Tests.ps1 tests it.
    Mock -ModuleName VmMigrationFactory Get-VmfTempDiskContentStop { $null }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"
    $script:dataFile = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json'

    function Global:RsSetRetire([int]$Days) {
        InModuleScope VmMigrationFactory -Parameters @{ d = $Days; file = $script:dataFile } {
            $f = Get-VmfTargetFamilyData -Path $file
            $copy = $f | ConvertTo-Json -Depth 30 | ConvertFrom-Json
            @($copy.lifecycle.retirements)[0].retiresUtc = (Get-Date).ToUniversalTime().Date.AddDays($d).ToString('yyyy-MM-dd')
            $script:VmfTargetFamilies = $copy
        }
    }
    function Global:RsReset {
        InModuleScope VmMigrationFactory -Parameters @{ file = $script:dataFile } { $null = Get-VmfTargetFamilyData -Path $file }
    }
    function Global:RsDay([int]$Days) { (Get-Date).ToUniversalTime().Date.AddDays($Days).ToString('yyyy-MM-dd') }
    function Global:RsVm([string]$Size = 'Standard_D2s_v3') {
        [pscustomobject]@{
            Name = 'vm1'; ResourceGroupName = 'rg-app'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = $Size }
            StorageProfile = [pscustomobject]@{
                DiskControllerType = 'SCSI'
                OsDisk = [pscustomobject]@{ OsType = 'Linux'; Name = 'vm1-os'; DeleteOption = 'Delete'
                    ManagedDisk = [pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1-os'; StorageAccountType = 'Premium_LRS' } }
                DataDisks = @(); ImageReference = $null
            }
            NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Network/networkInterfaces/nic0'; Primary = $true }) }
            Zones = @(); Tags = @{}
            LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
            Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
        }
    }
    # A migrated machine with both copies, its record made on D2s_v3.
    function Global:RsRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rs-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub } {
            param($rp, $id, $sub)
            Initialize-VmfRun -RunPath $rp -RunId 'rs' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rs' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -Force -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ name = 'vm1'; size = 'Standard_D2s_v3'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'; zones = @()
                        osDisk = [pscustomobject]@{ name = 'vm1-os'; skuName = 'Premium_LRS'; managedDiskId = "$sub/Microsoft.Compute/disks/vm1-os"; deleteOption = 'Delete' }
                        dataDisks = @(); tags = @{}; nics = @() } })
            $doc | Add-Member -NotePropertyName safety -Force -NotePropertyValue ([pscustomobject]@{
                    snapshotId = "$sub/Microsoft.Compute/snapshots/vm1-prepared"; cloneVmId = $null; locksAllowed = $true
                    pristineSnapshotId = "$sub/Microsoft.Compute/snapshots/vm1-pristine"; pristineSnapshotLocked = $true })
            $doc.state = 'MIGRATED'
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'
                        assessment = [ordered]@{ location = 'centralus'; os = 'Linux'; sourceSize = 'Standard_D2s_v3' }
                        target = [ordered]@{ size = 'Standard_D2s_v6'; controller = 'NVMe'; zone = $null }; path = 'A'; policy = [ordered]@{} }) }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
        }
        $rp
    }
    function Global:RsPlanEntry([string]$Size = 'Standard_D2s_v3') {
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'; path = 'A'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; sourceSize = $Size; sourceDiskArch = 'scsi-temp'; platformManaged = $false; location = 'centralus' }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe'; zone = $null }
            policy = [pscustomobject]@{ onDDataFound = 'proceed' } }
    }
    function Global:RsCatalog {
        foreach ($n in @('Standard_D2s_v3', 'Standard_D2s_v6', 'Standard_D2ds_v6', 'Standard_D2ds_v5', 'Standard_D2s_v5')) {
            [pscustomobject]@{ Name = $n; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = @(
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }, [pscustomobject]@{ Name = 'MemoryGB'; Value = '8' },
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }, [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' },
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $(if ($n -like '*_v6') { 'V2' } else { 'V1,V2' }) },
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $(if ($n -like '*_v3' -or $n -like '*ds_v5' -or $n -like '*ds_v6') { '16384' } else { '0' }) }) }
        }
    }
    function Global:RsCatalogMap { $m = @{}; foreach ($s in @(Global:RsCatalog)) { $m[$s.Name] = $s }; $m }
    # One assessed machine, as the scan records it.
    function Global:RsAssessed([string]$Size = 'Standard_D2s_v3', [string]$Gen = 'V2', [string[]]$Blockers = @()) {
        [ordered]@{ vmId = $script:vmId; name = 'vm1'; resourceGroup = 'rg-app'; location = 'centralus'; zones = @()
            classification = $(if ($Blockers.Count) { 'Blocked' } else { 'ReadyAfterPrep' }); gen = $Gen; os = 'Linux'; osVersion = '22_04-lts-gen2'; sourceSize = $Size
            sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = 'SCSI'; dataDiskCount = 0; nicCount = 1; acceleratedNicCount = 1
            primaryNicAccelerated = $true; platformManaged = $false; iacManaged = $false; hibernationEnabled = $false; availabilitySetId = ''
            identityType = 'None'; tags = @{}; blockers = @($Blockers); prepNeeded = @() }
    }
    function Global:RsAssessment([string]$RunPath, $Vm) {
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $RunPath -Leaf); generatedUtc = '2026-10-04T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}; vms = @($Vm) }
        InModuleScope VmMigrationFactory -Parameters @{ p0 = $RunPath; d = $doc } {
            Initialize-VmfRun -RunPath $p0 -RunId (Split-Path $p0 -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $p0 -RelPath 'assessment.json' -Document $d -Depth 24
        }
        Approve-VmfAssessment -RunPath $RunPath -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
    }
    Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
    Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
    Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
}
AfterAll {
    RsReset
    foreach ($fn in 'RsSetRetire', 'RsReset', 'RsDay', 'RsVm', 'RsRun', 'RsPlanEntry', 'RsCatalog', 'RsCatalogMap', 'RsAssessed', 'RsAssessment') {
        Remove-Item "function:\$fn" -ErrorAction SilentlyContinue
    }
}

Describe 'RETIRE-SCOPE-1: the rule' {
    AfterEach { RsReset }

    It 'out of scope from one day before the date, not two' {
        InModuleScope VmMigrationFactory {
            $at = { param([string]$Day) [datetime]::ParseExact($Day, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal) }
            Test-VmfSizeRetiredForTool -Size 'Standard_D2s_v3' -Now (& $at '2029-11-13') | Should -BeFalse
            Test-VmfSizeRetiredForTool -Size 'Standard_D2s_v3' -Now (& $at '2029-11-14') | Should -BeTrue
            Test-VmfSizeRetiredForTool -Size 'Standard_D2s_v3' -Now (& $at '2031-01-01') | Should -BeTrue
            Test-VmfSizeRetiredForTool -Size 'Standard_D2s_v4' -Now (& $at '2040-01-01') | Should -BeFalse
            Test-VmfSizeRetiredForTool -Size '' | Should -BeFalse
        }
    }

    It 'the words say scope, name the size and the date, and invent no technical limit' {
        RsSetRetire 0
        InModuleScope VmMigrationFactory -Parameters @{ day = (RsDay 0) } {
            param($day)
            $w = Get-VmfRetiredScopeDetail -Size 'Standard_D2s_v3'
            $w | Should -Match 'outside the scope of this tool'
            $w | Should -Match ([regex]::Escape("Microsoft retired Standard_D2s_v3 on $day")) -Because 'REVIEW: the date is today, so it is past'
            $w | Should -Not -Match 'cannot|impossible|current size'
            Get-VmfRetiredScopeDetail -Size 'Standard_D2s_v4' | Should -BeNullOrEmpty
        }
    }

    It 'REVIEW: the refusal of a restore is one sentence of at most 25 words, and a date not yet passed is said as future' {
        RsSetRetire 1
        $r = InModuleScope VmMigrationFactory { Get-VmfPutBackRetirementCheck -Size 'Standard_D2s_v3' -VmName 'vm1' }
        $r.Refuse | Should -BeTrue
        @($r.Detail -split '\s+').Count | Should -BeLessOrEqual 25 -Because $r.Detail
        (InModuleScope VmMigrationFactory { Get-VmfRetiredScopeDetail -Size 'Standard_D2s_v3' }) | Should -Match '^Microsoft retires '
    }
    It 'the warning is said within the 12 months before the margin, and not before or after them' {
        foreach ($case in @(@{ Days = 2; Says = $true }, @{ Days = 300; Says = $true }, @{ Days = 400; Says = $false }, @{ Days = 1; Says = $false })) {
            RsSetRetire $case.Days
            $w = InModuleScope VmMigrationFactory { Get-VmfRetirementWarning -Size 'Standard_D2s_v3' }
            if ($case.Says) { $w | Should -Match 'outside the scope of this tool' -Because "$($case.Days) days" }
            else { $w | Should -BeNullOrEmpty -Because "$($case.Days) days" }
        }
    }
}

Describe 'RETIRE-SCOPE-1: the assessment says so' {
    AfterEach { RsReset }

    It '<Case>' -ForEach @(
        @{ Case = 'the date is today: out of scope'; Days = 0; Blocked = $true }
        @{ Case = 'the date is tomorrow: out of scope - a rollback could cross midnight'; Days = 1; Blocked = $true }
        @{ Case = 'the date is two days away: in scope'; Days = 2; Blocked = $false }
    ) {
        RsSetRetire $Days
        $vm = [pscustomobject]@{ vmId = '/s/rg/vm/x1'; id = '/s/rg/vm/x1'; name = 'x1'; sku = 'Standard_D2s_v3'; location = 'centralus'; resourceGroup = 'rg'
            os = 'Linux'; gen = 'V2'; tags = @{}; nicIds = @(); dataDiskCount = 0; osDiskManaged = $true; securityType = '' }
        $r = InModuleScope VmMigrationFactory -Parameters @{ v = $vm } { param($v) Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -NicAcceleratedMap @{} -ManagedPlatformGroups @{} -SapSystemVms @{} -AvdSessionHosts @{} }
        if ($Blocked) {
            @($r.blockers) | Should -Contain 'size-retired'
            $r.classification | Should -Be 'Blocked'
            (@($r.notes) -join ' ') | Should -Match "Microsoft $(if ($Days -eq 0) { 'retired' } else { 'retires' }) Standard_D2s_v3 on $(RsDay $Days)"
        }
        else { @($r.blockers) | Should -Not -Contain 'size-retired' }
    }

    It 'the reason has words that say scope, a link to Microsoft''s page, and applies to every series' {
        $reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
        $r = $reasons.blockers.'size-retired'
        $r | Should -Not -BeNullOrEmpty
        $r.title | Should -Match 'not in scope'
        $r.meaning | Should -Match 'outside the scope of this tool'
        $r.whatToDo | Should -Match 'assess'
        foreach ($field in 'meaning', 'whatToDo') { $r.$field | Should -Not -Match 'cannot|impossible|current size' }
        $r.docs.url | Should -Match '^https://learn\.microsoft\.com/'
        @($r.appliesTo) | Should -Be @('v5', 'v6', 'v7')
    }
}

Describe 'RETIRE-SCOPE-1: the target advice gives no option' {
    AfterEach { RsReset }

    It 'from the margin, every series is not supported for size-retired - even on an assessment made before it' {
        RsSetRetire 1
        $vm = [pscustomobject](Global:RsAssessed)
        $advice = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = (Global:RsCatalogMap) } {
            param($v, $c) Get-VmfTargetAdvice -Assessment ([pscustomobject]@{ runId = 'x'; vms = @($v) }) -CatalogByLocation @{ centralus = $c }
        }
        $m = $advice.machines[0]
        @($m.options | Where-Object { $_.supported }).Count | Should -Be 0
        foreach ($o in @($m.options)) { @($o.notSupported) | Should -Contain 'size-retired' -Because $o.option }
        $m.start.current | Should -BeNullOrEmpty
        $m.start.extended | Should -BeNullOrEmpty
    }

    It 'a Generation 1 machine on a retired size has the three series, and none is supported' {
        RsSetRetire 0
        $vm = [pscustomobject](Global:RsAssessed -Gen 'V1')
        $advice = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = (Global:RsCatalogMap) } {
            param($v, $c) Get-VmfTargetAdvice -Assessment ([pscustomobject]@{ runId = 'x'; vms = @($v) }) -CatalogByLocation @{ centralus = $c }
        }
        @($advice.machines[0].options.option) | Should -Be @('v5', 'v6', 'v7')
        @($advice.machines[0].options | Where-Object supported).Count | Should -Be 0
    }

    It 'two days before the date: the options are as they were' {
        RsSetRetire 2
        $vm = [pscustomobject](Global:RsAssessed)
        $advice = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = (Global:RsCatalogMap) } {
            param($v, $c) Get-VmfTargetAdvice -Assessment ([pscustomobject]@{ runId = 'x'; vms = @($v) }) -CatalogByLocation @{ centralus = $c }
        }
        @($advice.machines[0].options | Where-Object { $_.supported }).Count | Should -BeGreaterThan 0
        ($advice | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
    }

    It 'the advice document with the new reason meets its schema, at the version the engine writes' {
        RsSetRetire 0
        $vm = [pscustomobject](Global:RsAssessed)
        $advice = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = (Global:RsCatalogMap) } {
            param($v, $c) Get-VmfTargetAdvice -Assessment ([pscustomobject]@{ runId = 'x'; vms = @($v) }) -CatalogByLocation @{ centralus = $c }
        }
        $advice.assessmentHash = 'h'
        ($advice | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
        $advice.schemaVersion | Should -Be 34 -Because 'SIZE-FALLTHROUGH-NOTE-1 made it 29 (sizesNotTaken); REBUILD-REMOVE-PLAN-1 made it 28 (no rebuild); AN-MANA-DRIVER-RULE-1 made it 27 (the reason no-mana-driver); DRIFT-11-OTHER-OPTIONS-1 made it 26 (the reason an-required-no-mana); NO-PLAN-SCOPE-1 made it 25 (the reason purchase-plan-out-of-scope); TEMP-DISK-PREVIEW-1 made it 24 (preview); REBUILD-PICKER-1 made it 23; GEN1-ROUTE-GONE-1 made it 22; IDENTITY-LOSS-1 made it 21; v18 (ADVISE-AN-1) added keptOn; v19 (DETECT-PATTERNS-1) four workload reasons outside the scope of this tool; v20 (HDD-OS-1) the OS disk type of each machine'
    }
}

Describe 'RETIRE-SCOPE-1: the plan' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { Global:RsCatalog }
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rsa-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:mig = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rsm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        RsAssessment $script:rp (Global:RsAssessed)
    }
    AfterEach { RsReset; foreach ($d in $script:rp, $script:mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } } }

    It '<Case>' -ForEach @(
        @{ Case = 'the date is today: not planned, and the plan says it is outside the scope'; Days = 0; Path = 'MANUAL'; Note = 'outside the scope of this tool' }
        @{ Case = 'the date is tomorrow: not planned either'; Days = 1; Path = 'MANUAL'; Note = 'outside the scope of this tool' }
        @{ Case = 'within 12 months: planned, and the notes give the date'; Days = 60; Path = 'A'; Note = 'Microsoft retires Standard_D2s_v3' }
        @{ Case = 'further away: planned, and nothing said'; Days = 500; Path = 'A'; Note = $null }
    ) {
        RsSetRetire $Days
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig | Out-Null
        $entry = @((Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries)[0]
        $entry.path | Should -Be $Path
        $entry.target.PSObject.Properties['rollbackSize'] | Should -BeNullOrEmpty -Because 'the plan no longer writes a rollback size'
        if ($Path -eq 'MANUAL') {
            $entry.target.size | Should -BeNullOrEmpty
            $entry.wave | Should -Be 'unscheduled'
        }
        if ($Note) { ($entry.planNotes -join ' ') | Should -Match ([regex]::Escape($Note)) } else { @($entry.planNotes).Count | Should -Be 0 }
        ($entry | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') | Should -BeTrue
    }
}

Describe 'RETIRE-SCOPE-1: the wave editor' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { Global:RsCatalog }
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rsw-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:mig = "$($script:rp)-migration"
        RsAssessment $script:rp (Global:RsAssessed)
        RsSetRetire 60
        New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') | Out-Null
        $v = InModuleScope VmMigrationFactory -Parameters @{ p0 = $script:rp } {
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $p0 -RelPath 'target-advice.json')) }
        Set-VmfTestTargetChoice -RunPath $script:rp -Default 'current' -ExpectedAdviceVersion $v -ExpectedChoicesVersion '' `
            -Choices @(@{ vmId = $script:vmId; option = 'v6' }) -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig | Out-Null
    }
    AfterEach { RsReset; foreach ($d in $script:rp, $script:mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } } }

    It 'within the 12 months: a new series keeps the warning, and writes no rollback size' {
        $entry = { @((Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries)[0] }
        ((& $entry).planNotes -join ' ') | Should -Match 'Microsoft retires Standard_D2s_v3'
        $r = Set-VmfMachineTarget -RunPath $script:mig -VmId $script:vmId -Option v5 -ChangedBy 'operator@example.com' -Confirm:$false
        $r.Applied | Should -BeTrue
        ((& $entry).planNotes -join ' ') | Should -Match 'Microsoft retires Standard_D2s_v3'
        (& $entry).target.PSObject.Properties['rollbackSize'] | Should -BeNullOrEmpty
    }

    It 'from the margin: the change is refused in words that say scope, and the plan is not written' {
        $before = Get-Content (Join-Path $script:mig 'plan.json') -Raw
        RsSetRetire 1
        { Set-VmfMachineTarget -RunPath $script:mig -VmId $script:vmId -Option v5 -ChangedBy 'operator@example.com' -Confirm:$false } |
            Should -Throw '*outside the scope of this tool*'
        Get-Content (Join-Path $script:mig 'plan.json') -Raw | Should -Be $before
    }
}

Describe 'RETIRE-SCOPE-1: PRECHECK refuses it untouched' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rsp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'rsp' | Out-Null }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        # SAFETY-CMK-1: PRECHECK reads each disk's encryption by its id.
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { @() }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { Global:RsVm }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { Global:RsCatalog }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'the machine must not be touched' }
    }
    AfterEach { RsReset; if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It '<Case>' -ForEach @(
        @{ Case = 'the date is today: refused, untouched, with the scope words'; Days = 0; Refused = $true; Says = 'outside the scope of this tool' }
        @{ Case = 'the date is tomorrow: refused - a rollback could cross midnight'; Days = 1; Refused = $true; Says = 'outside the scope of this tool' }
        @{ Case = 'the date is two days away: the move goes on, and the log warns'; Days = 2; Refused = $false; Says = 'Microsoft retires Standard_D2s_v3' }
        @{ Case = 'the date is more than a year away: the move goes on, and nothing is said'; Days = 400; Refused = $false; Says = $null }
    ) {
        RsSetRetire $Days
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; days = $Days; refused = $Refused; says = $Says; plan = (Global:RsPlanEntry) } {
            param($rp, $days, $refused, $says, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'rsp'
            New-VmfStateDoc -RunPath $rp -RunId 'rsp' -VmId $ctx.VmId | Out-Null
            $r = Invoke-VmfStepPrecheck -Context $ctx
            if ($refused) {
                $r.Next | Should -Be 'NEEDS_DECISION'
                $r.Reason | Should -Be 'sizeRetired'
                $r.Detail | Should -Match ([regex]::Escape($says))
                $r.Detail | Should -Match 'Nothing on the machine changed'
                $r.Detail | Should -Match 'Resize the machine'
            }
            else {
                $r.Next | Should -Be 'SAFETY_PRISTINE'
                $rec = (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.putBackRetirement
                $rec.size | Should -Be 'Standard_D2s_v3'
                $rec.retiresUtc | Should -Be ((Get-Date).ToUniversalTime().Date.AddDays($days).ToString('yyyy-MM-dd'))
                $rec.PSObject.Properties['currentSize'] | Should -BeNullOrEmpty -Because 'no current size is chosen any more'
                $rec.PSObject.Properties['rollbackSize'] | Should -BeNullOrEmpty
            }
            $events = if (Test-Path (Join-Path $rp 'logs' 'events.jsonl')) { Get-Content (Join-Path $rp 'logs' 'events.jsonl') -Raw } else { '' }
            if (-not $refused) {
                if ($says) { $events | Should -Match ([regex]::Escape($says)) } else { $events | Should -Not -Match 'Microsoft retires' }
            }
        }
        Should -Invoke Get-VmfSkuCatalog -ModuleName VmMigrationFactory -Times 0 -Exactly -Because 'no current size is looked for'
    }

    It 'REVIEW: the size the plan was made for is asked first - before a refusal a person can correct, such as missing permissions' {
        RsSetRetire 1
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { throw 'the permission check must not be reached' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { throw 'the machine must not be read' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (Global:RsPlanEntry) } {
            param($rp, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'rsp'
            New-VmfStateDoc -RunPath $rp -RunId 'rsp' -VmId $ctx.VmId | Out-Null
            $r = Invoke-VmfStepPrecheck -Context $ctx
            $r.Reason | Should -Be 'sizeRetired'
            $r.Detail | Should -Match 'outside the scope of this tool'
        }
    }

    It 'ROLLBACK-RETRY-CAPTURE-1: a retry after the product touched the machine judges the FIRST capture''s size, in words that do not tell it to resize' {
        # The plan's own size is a size with no retirement here, so this
        # reaches the check on the size a rollback returns to.
        RsSetRetire 0
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { Global:RsVm -Size 'Standard_D2s_v6' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (Global:RsPlanEntry -Size 'Standard_D2s_v4') } {
            param($rp, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'rsp'
            New-VmfStateDoc -RunPath $rp -RunId 'rsp' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ original = [ordered]@{ vmConfig = [ordered]@{ size = 'Standard_D2s_v3' } } }
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId
            $doc | Add-Member -NotePropertyName rollback -Force -NotePropertyValue ([pscustomobject]@{ rolledBackUtc = '2026-10-01T00:00:00Z'; path = 'A'; osDisk = $null; dataDisks = @() })
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $plan.target.size = 'Standard_D2ds_v6'
            $r = Invoke-VmfStepPrecheck -Context $ctx
            $r.Reason | Should -Be 'sizeRetired'
            $r.Detail | Should -Match 'A rollback returns this machine to Standard_D2s_v3'
            $r.Detail | Should -Not -Match 'Resize' -Because 'REVIEW: the machine already runs on a supported size'
            (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.putBackRetirement.size | Should -Be 'Standard_D2s_v3'
        }
    }

    It 'a size with no retirement records nothing - and clears a record an earlier check left' {
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { Global:RsVm -Size 'Standard_D2s_v4' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (Global:RsPlanEntry -Size 'Standard_D2s_v4') } {
            param($rp, $plan)
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'rsp'
            New-VmfStateDoc -RunPath $rp -RunId 'rsp' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ putBackRetirement = [ordered]@{ size = 'Standard_D2s_v4'; retiresUtc = '2027-01-01'; warnFromUtc = '2026-01-01'; rollbackSize = 'Standard_D2s_v5' } }
            (Invoke-VmfStepPrecheck -Context $ctx).Next | Should -Be 'SAFETY_PRISTINE'
            (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.putBackRetirement | Should -BeNullOrEmpty
        }
    }

    It 'an old plan entry that carries a rollback size (plan-entry v18) is refused the same way - the field is not read' {
        RsSetRetire 0
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (Global:RsPlanEntry) } {
            param($rp, $plan)
            $plan.target | Add-Member -NotePropertyName rollbackSize -NotePropertyValue 'Standard_D2ds_v5' -Force
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'rsp'
            New-VmfStateDoc -RunPath $rp -RunId 'rsp' -VmId $ctx.VmId | Out-Null
            (Invoke-VmfStepPrecheck -Context $ctx).Reason | Should -Be 'sizeRetired'
        }
    }

    It 'OLD-FAM-4 review: a plan made before the date and run from the day before is refused at the check, before any safety copy - not left changed' {
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { throw 'no safety copy may be taken' }
        $ar = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rsx-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $mig = "$ar-migration"
        try {
            RsAssessment $ar (Global:RsAssessed)
            RsSetRetire 60
            New-VmfPlan -AssessmentPath (Join-Path $ar 'assessment.json') -OutPath $mig | Out-Null
            $entry = @((Get-Content (Join-Path $mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries)[0]
            $entry.path | Should -Be 'A' -Because 'planned while the date was two months away'
            RsSetRetire 1
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = $entry } {
                param($rp, $plan)
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'rsp'
                New-VmfStateDoc -RunPath $rp -RunId 'rsp' -VmId $ctx.VmId | Out-Null
                $r = Invoke-VmfStepPrecheck -Context $ctx
                $r.Next | Should -Be 'NEEDS_DECISION'
                $r.Reason | Should -Be 'sizeRetired'
            }
            Should -Invoke New-VmfOsDiskSnapshot -ModuleName VmMigrationFactory -Times 0 -Exactly
            Should -Invoke Stop-VmfVmDeallocated -ModuleName VmMigrationFactory -Times 0 -Exactly
        }
        finally { foreach ($d in $ar, $mig) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } } }
    }

    It 'the stop has guidance: untouched, and a retry of this plan does not help' {
        $all = @((Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons)
        $reason = $all | Where-Object code -eq 'sizeRetired'
        $reason.machine | Should -Be 'untouched'
        $reason.retry | Should -Be 'outOfScope' -Because 'REVIEW: notSupported says this version cannot migrate it, which is not a scope answer'
        @((Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).retryLines.outOfScope) | Should -Match 'outside the scope of this tool'
        $reason.meaning | Should -Match 'outside the scope of this tool'
        $reason.whatToDo | Should -Match 'assess'
        $reason.whatToDo | Should -Not -Match 'current size|v5 size'
        @($all | Where-Object code -eq 'putBackSizeRetired').Count | Should -Be 0 -Because 'the nearest-current-size stop is gone'
    }
}

Describe 'RETIRE-SCOPE-1: the automatic rollback goes to the original size' {
    BeforeEach {
        $global:rsCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:rsCalls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:rsCalls.Add('start') }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-os'; id = '/d/vm1-os'; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 30; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:rsCalls.Add("swap:$DiskName") }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:rsCalls.Add("hardware:$Size/$Controller") }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $global:rsCalls.Add("an:$NicId=$Enabled"); $true }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { Global:RsCatalog }
        $script:rp = RsRun
    }
    AfterEach { RsReset; if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable rsCalls -Scope Global -ErrorAction SilentlyContinue }

    It 'a record V3-RETIRE-1 wrote with a current size (vm-state v17) is read and ignored: back to its own size, and no size is written to the rollback record' {
        # The margin day: the size still runs, so a rollback still goes to it.
        RsSetRetire 1
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc.captured | Add-Member -NotePropertyName putBackRetirement -Force -NotePropertyValue ([pscustomobject]@{
                    size = 'Standard_D2s_v3'; retiresUtc = '2029-11-15'; warnFromUtc = '2028-11-15'; currentSize = 'Standard_D2ds_v5'; rollbackSize = 'Standard_D2ds_v5' })
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = 'A'; wave = 'w1'; target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe'; rollbackSize = 'Standard_D2ds_v5' } }
            Invoke-VmfRollback -Context (New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'rs')
            $after = Read-VmfStateDoc -RunPath $rp -VmId $id
            $after.rollback | Should -Not -BeNullOrEmpty
            $after.rollback.PSObject.Properties['sizeAfter'] | Should -BeNullOrEmpty -Because 'the rollback no longer records another size'
        }
        @($global:rsCalls) | Should -Contain 'hardware:Standard_D2s_v3/SCSI'
        @($global:rsCalls) | Should -Not -Contain 'hardware:Standard_D2ds_v5/SCSI'
        Should -Invoke Get-VmfSkuCatalog -ModuleName VmMigrationFactory -Times 0 -Exactly
    }

    It 'REVIEW: past the retirement date (a move resumed after PRECHECK), the rollback is not started - nothing is stopped or changed, and the words say scope' {
        RsSetRetire 0
        # REBUILD-REMOVE-ENGINE-1: on Path A - the rollback has no Path B now.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId; day = (RsDay 0) } {
            param($rp, $id, $day)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = 'A'; wave = 'w1'; target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' } }
            { Invoke-VmfRollback -Context (New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'rs') } |
                Should -Throw "Microsoft retired Standard_D2s_v3 on $day*outside the scope of this tool*did not start the rollback*"
        }
        @($global:rsCalls).Count | Should -Be 0 -Because "nothing may be stopped, swapped or resized: $(@($global:rsCalls) -join ', ')"
        Should -Invoke New-VmfDiskFromSnapshot -ModuleName VmMigrationFactory -Times 0 -Exactly
    }

    It 'before the margin with no record: its own size, as always' {
        RsSetRetire 30
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = 'A'; wave = 'w1'; target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' } }
            Invoke-VmfRollback -Context (New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'rs')
        }
        @($global:rsCalls) | Should -Contain 'hardware:Standard_D2s_v3/SCSI'
    }
}

Describe 'RETIRE-SCOPE-1: a person''s restore and rebuild' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-os'; id = '/d/vm1-os'; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 30; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $true }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { Global:RsCatalog }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v6' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
        $script:rp = RsRun
    }
    AfterEach { RsReset; if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'Restore this machine from the first copy, from the margin: refused before the machine is stopped, in words that say scope' {
        foreach ($days in 0, 1) {
            RsSetRetire $days
            { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } |
                Should -Throw "Nothing changed for vm1, because a return to Standard_D2s_v3 is outside the scope of this tool from one day before Microsoft $(if ($days -eq 0) { 'retired' } else { 'retires' }) it on $(RsDay $days)."
        }
        Should -Invoke Stop-VmfVmDeallocated -ModuleName VmMigrationFactory -Times 0 -Exactly
        Should -Invoke New-VmfDiskFromSnapshot -ModuleName VmMigrationFactory -Times 0 -Exactly
        Should -Invoke Set-VmfVmSizeAndController -ModuleName VmMigrationFactory -Times 0 -Exactly
        Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') -Raw | Should -Match '"step":"putBack"'
    }

    It '-WhatIf writes nothing and refuses nothing' {
        RsSetRetire 0
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -WhatIf | Out-Null
        (Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') -Raw -ErrorAction SilentlyContinue) | Should -Not -Match 'putBack'
    }

    It 'two days before the date: its own size, and the log warns with the date' {
        RsSetRetire 2
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        Should -Invoke Set-VmfVmSizeAndController -ModuleName VmMigrationFactory -ParameterFilter { $Size -eq 'Standard_D2s_v3' }
        Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') -Raw | Should -Match ([regex]::Escape("Microsoft retires Standard_D2s_v3 on $(RsDay 2)"))
        Should -Invoke Get-VmfSkuCatalog -ModuleName VmMigrationFactory -Times 0 -Exactly
    }

    It 'from the other copy, from the margin: as before - that copy keeps the size the machine has now' {
        RsSetRetire 0
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false | Out-Null
        Should -Invoke Stop-VmfVmDeallocated -ModuleName VmMigrationFactory -Times 1
        Should -Invoke Set-VmfVmSizeAndController -ModuleName VmMigrationFactory -Times 0 -Exactly -ParameterFilter { $Size -eq 'Standard_D2s_v3' }
    }

    # REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine and the restore that rebuilds.

    # REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine and the restore that rebuilds.

    # REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine and the restore that rebuilds.
}

Describe 'RETIRE-SCOPE-1: the service refuses a restore on RETRY-GATE-1''s path' {
    BeforeAll {
        $script:storeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rss-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:storeRoot | Out-Null
        $script:oldStore = $env:VMF_STORE_PATH
        $env:VMF_STORE_PATH = $script:storeRoot
        $made = RsRun
        Move-Item $made (Join-Path $script:storeRoot 'r1')
    }
    AfterAll {
        $env:VMF_STORE_PATH = $script:oldStore
        if ($script:storeRoot -and (Test-Path $script:storeRoot)) { Remove-Item $script:storeRoot -Recurse -Force }
    }
    AfterEach { RsReset }

    It 'from the margin: a restore from the first copy is refused with a 400 that names the machine, before a job starts - with no saved size catalog' {
        RsSetRetire 1
        $caller = [pscustomobject]@{ Identity = 'tester'; Roles = @('Vmf.Operator') }
        { Invoke-VmfFacadeStartEngine -Principal $caller -Operation restore -RunId r1 -VmId $script:vmId -Note 'n' -DiskSource pristine -ErrorAction Stop } |
            Should -Throw -ExpectedMessage "400: Nothing changed for vm1, because a return to Standard_D2s_v3 is outside the scope of this tool*$(RsDay 1)*"
    }

    It 'the other copy, or a date two days away: past this check, to the engine' {
        $caller = [pscustomobject]@{ Identity = 'tester'; Roles = @('Vmf.Operator') }
        foreach ($case in @(
                @{ Days = 0; Extra = @{ Operation = 'restore'; DiskSource = 'prepared' } },
                @{ Days = 2; Extra = @{ Operation = 'restore'; DiskSource = 'pristine' } })) {
            RsSetRetire $case.Days
            $extra = $case.Extra
            $failed = $null
            try { Invoke-VmfFacadeStartEngine -Principal $caller -RunId r1 -VmId $script:vmId -Note 'n' @extra -ErrorAction Stop | Out-Null } catch { $failed = $_.Exception.Message }
            $failed | Should -Not -BeLike '*Nothing changed*'
            $failed | Should -BeLike '*VMF_ENGINE_JOB_ID*' -Because 'it got as far as wanting the engine job'
        }
    }
}

Describe 'RETIRE-SCOPE-1: documents that carry the fields no longer written' {
    It 'OLD-VERSION-READERS-REMOVE-3: a plan entry with target.rollbackSize is refused by the contract (plan-entry v33)' {
        $entry = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json') -Raw | ConvertFrom-Json -Depth 30
        $entry.target.PSObject.Properties['rollbackSize'] | Should -BeNullOrEmpty -Because 'the sample shows what the product writes now'
        ($entry | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') | Should -BeTrue
        $entry.target | Add-Member -NotePropertyName rollbackSize -NotePropertyValue 'Standard_D4ds_v5' -Force
        ($entry | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -ErrorAction SilentlyContinue | Should -BeFalse
    }
    It 'OLD-VERSION-READERS-REMOVE-4: rollback.sizeAfter is not in the contract (v47); the old putBackRetirement fields are refused (OLD-STATE-READERS-FINISH-1, v48)' {
        $doc = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw | ConvertFrom-Json -Depth 40
        $doc | Add-Member -NotePropertyName rollback -Force -NotePropertyValue ([pscustomobject]@{ rolledBackUtc = '2026-10-03T00:00:00Z'; path = 'A'; sizeAfter = 'Standard_D2ds_v5'; osDisk = $null; dataDisks = @() })
        ($doc | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -ErrorAction SilentlyContinue | Should -BeFalse
        $doc.rollback.PSObject.Properties.Remove('sizeAfter')
        if (-not $doc.captured) { $doc | Add-Member -NotePropertyName captured -Force -NotePropertyValue ([pscustomobject]@{}) }
        $doc.captured | Add-Member -NotePropertyName putBackRetirement -Force -NotePropertyValue ([pscustomobject]@{
                size = 'Standard_D2s_v3'; retiresUtc = '2029-11-15'; warnFromUtc = '2028-11-15'; currentSize = 'Standard_D2ds_v5'; rollbackSize = 'Standard_D2ds_v5' })
        ($doc | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -ErrorAction SilentlyContinue | Should -BeFalse
        $doc.captured.putBackRetirement.PSObject.Properties.Remove('currentSize'); $doc.captured.putBackRetirement.PSObject.Properties.Remove('rollbackSize')
        ($doc | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') | Should -BeTrue
    }

    It 'the removed machinery is gone from the module' {
        InModuleScope VmMigrationFactory {
            foreach ($fn in 'Get-VmfCurrentRollbackSize', 'Get-VmfMoveRollbackPlan', 'Get-VmfRecordedRollbackSize', 'ConvertTo-VmfRollbackDoc',
                             'Resolve-VmfRollbackSize', 'Get-VmfRollbackAssessment') {
                Get-Command $fn -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because $fn
            }
        }
    }
}
