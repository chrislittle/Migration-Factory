#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# NO-PLAN-SCOPE-1 (1.0), 2026-11-03: the tool does not support third-party
# moves. A machine with a Marketplace purchase plan is outside
# the scope of this tool, for 1.0 because no edition with a plan was ever
# tested (ruling, the same day, after the sweep in the item showed that
# Ubuntu Pro, RHEL BYOS and the SUSE "-llc" offers carry one).
#
#   - The scan: a blocker outside the scope of this tool on every series
#     (purchase-plan-out-of-scope), with the plan as evidence. A network
#     virtual appliance, a storage appliance and a machine in a managed
#     application keep their own reason: each says more than "a plan".
#   - Checking: a machine whose plan the scan never saw (an older plan) stops
#     untouched (purchasePlan), from the machine's plan or its OS disk's plan.
#   - The rebuild sends no plan: REBUILD-PROPS-1's carry-over is removed, and
#     the capture no longer records one (vm-state v34).
#
# The images a machine of a supported image is made from carry NO plan: the
# fixture holds what Azure returned on 2026-11-03, and the walk below fails
# when a supported publisher has no image in it.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:images = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'supported-image-plans.json') -Raw | ConvertFrom-Json
    $script:matrix = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'supported-images.json') -Raw | ConvertFrom-Json
    $script:reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
    $script:stops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
    $script:npVm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1'
    $script:npDisk = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/'

    # One inventory row, in the shape the discovery query projects it.
    function Global:NpRow {
        param(
            [string]$Publisher = 'Canonical', [string]$Offer = '0001-com-ubuntu-server-jammy', [string]$Sku = '22_04-lts-gen2',
            [string]$Os = 'Linux',
            [string]$PlanPublisher = '', [string]$PlanProduct = '', [string]$PlanName = '',
            [string]$ImageId = '',
            [switch]$NoPlanName
        )
        $sub = '00000000-0000-0000-0000-000000000000'
        $row = [pscustomobject]@{
            id = "/subscriptions/$sub/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1"
            name = 'vm1'; resourceGroup = 'rg-app'; location = 'centralus'; zones = $null
            sku = 'Standard_D2ds_v4'; os = $Os; gen = 'V2'; diskController = 'SCSI'
            osName = $(if ($Os -eq 'Windows') { 'Windows Server 2022 Datacenter' } else { 'ubuntu' })
            imagePublisher = $Publisher; imageOffer = $Offer; imageSku = $Sku; imageId = $ImageId
            communityGalleryImageId = ''; sharedGalleryImageId = ''
            planPublisher = $PlanPublisher; planProduct = $PlanProduct
            vmssId = ''; hibernationEnabled = $false; securityType = ''; dataDiskCount = 0; dataDisks = @()
            tags = $null; identityType = 'None'; identityPrincipalId = ''
            adeOsDiskEnabled = ''; licenseType = ''; osDiskManagedId = "/subscriptions/$sub/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1-os"
        }
        # An inventory row from before this item has no planName.
        if (-not $NoPlanName) { $row | Add-Member -NotePropertyName planName -NotePropertyValue $PlanName }
        $row
    }
    function Global:NpSku {
        [pscustomobject]@{
            Name = 'Standard_D2ds_v4'; ResourceType = 'virtualMachines'; Family = 'StandardDDSv4Family'
            Capabilities = @([pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '76800' }, [pscustomobject]@{ Name = 'vCPUs'; Value = '2' })
            Restrictions = @()
        }
    }
    function Global:NpKnown {
        param([hashtable]$Over = @{})
        $facts = @{
            SapSystemVms = @{}; AvdSessionHosts = @{}; AvdPoolTypes = @{}; ManagedPlatformGroups = @{}
            SqlVms = @{}; DiskShares = @{}; NicClusterHints = @{}; SqlAgentVms = @{}
            ResourceGroupOwners = @{ '00000000-0000-0000-0000-000000000000/rg-app' = '' }
        }
        foreach ($k in $Over.Keys) { $facts[$k] = $Over[$k] }
        $facts
    }
    # The machine as Get-VmfVmConfig returns it (the Get-AzVM shape).
    function Global:NpLiveVm {
        param([string]$Publisher = 'Canonical', [string]$Offer = '0001-com-ubuntu-server-jammy',
            [string]$PlanPublisher = '', [string]$PlanProduct = '', [string]$PlanName = '', [string]$ImageId = '')
        [pscustomobject]@{
            Id = $script:npVm; Name = 'vm1'
            Plan = $(if ($PlanPublisher -or $PlanProduct -or $PlanName) { [pscustomobject]@{ Publisher = $PlanPublisher; Product = $PlanProduct; Name = $PlanName; PromotionCode = $null } } else { $null })
            StorageProfile = [pscustomobject]@{
                ImageReference = [pscustomobject]@{ Publisher = $Publisher; Offer = $Offer; Sku = 'sku1'; Id = $ImageId; CommunityGalleryImageId = ''; SharedGalleryImageId = '' }
                DataDisks = @([pscustomobject]@{ Lun = 0; Name = 'vm1-data0'; ManagedDisk = [pscustomobject]@{ Id = "$($script:npDisk)vm1-data0" } })
            }
        }
    }
    function Global:NpCtx {
        @{ Plan = [pscustomobject]@{ assessment = [pscustomobject]@{ os = 'Linux' } }
           Rg = 'rg-app'; VmName = 'vm1'; VmId = $script:npVm; RunPath = $script:npRun }
    }

}

# The cases are read when Pester finds the tests, before BeforeAll runs.
BeforeDiscovery {
    $fixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'supported-image-plans.json') -Raw | ConvertFrom-Json
    $supportedCases = @($fixture.supported | ForEach-Object { @{ Name = "$($_.publisher):$($_.offer):$($_.sku):$($_.version)"; Ref = $_ } })
    $planCases = @($fixture.withPlan | ForEach-Object { @{ Name = "$($_.edition) ($($_.publisher):$($_.offer):$($_.sku))"; Ref = $_ } })
}

AfterAll {
    Remove-Item 'function:\NpRow', 'function:\NpSku', 'function:\NpKnown', 'function:\NpLiveVm', 'function:\NpCtx' -ErrorAction SilentlyContinue
}

Describe 'NO-PLAN-SCOPE-1: the images of the support matrix carry no purchase plan, and stay in scope' {
    It 'the fixture has an image of every publisher the support matrix lists as supported' {
        $listed = @($script:matrix.publishers | Where-Object { [string]$_.support -ne 'unsupported' } | ForEach-Object { [string]$_.publisher })
        # IMAGE-SCRIPT-MATCH-1 refused MicrosoftCBLMariner by offer and CLIENT-IMAGE-DATA-1
        # MicrosoftWindowsDesktop, so eight publishers are supported.
        $listed.Count | Should -BeGreaterThan 7
        foreach ($pub in $listed) {
            @($script:images.supported | Where-Object { [string]$_.publisher -eq $pub }).Count | Should -BeGreaterThan 0 -Because "the support matrix lists $pub as supported, so an image of it must be read for a plan and held here"
        }
        foreach ($ref in $script:images.supported) {
            $ref.PSObject.Properties.Name | Should -Not -Contain 'plan' -Because "$($ref.publisher):$($ref.offer):$($ref.sku) carried no plan when Azure was read"
            $listed | Should -Contain ([string]$ref.publisher)
        }
    }

    # PUBLIC-SYNC-1: lab/ does not ship to the public repository.
    It 'the lab builder''s images are among the images read' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'lab'))) {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'lab' 'deploy.ps1')
        $refs = [regex]::Matches($code, "publisher = '([^']+)'; offer = '([^']+)'\s+sku = '([^']+)'")
        $refs.Count | Should -BeGreaterThan 5
        foreach ($m in $refs) {
            $hit = @($script:images.supported | Where-Object { $_.publisher -eq $m.Groups[1].Value -and $_.offer -eq $m.Groups[2].Value -and $_.sku -eq $m.Groups[3].Value })
            $hit.Count | Should -BeGreaterThan 0 -Because "the lab builds $($m.Groups[1].Value):$($m.Groups[2].Value):$($m.Groups[3].Value)"
        }
    }

    It 'a machine of a supported image, with no plan, gets no purchase plan blocker: <Name>' -TestCases $supportedCases {
        InModuleScope VmMigrationFactory -Parameters @{ f = (NpKnown); row = (NpRow -Publisher $Ref.publisher -Offer $Ref.offer -Sku $Ref.sku -Os $Ref.os) } {
            param($f, $row)
            $rec = Get-VmfAssessmentRecord -Vm $row -SkuEntry (NpSku) @f
            @($rec.blockers) | Should -Not -Contain 'purchase-plan-out-of-scope'
            @($rec.notes | Where-Object { $_ -match 'purchase plan' }).Count | Should -Be 0
        }
    }

    It 'a machine of a supported image, with no plan, goes on at Checking: <Name>' -TestCases $supportedCases {
        InModuleScope VmMigrationFactory -Parameters @{ v = (NpLiveVm -Publisher $Ref.publisher -Offer $Ref.offer) } {
            param($v)
            (Get-VmfLivePurchasePlanVerdict -Vm $v) | Should -BeNullOrEmpty
        }
    }
}

Describe 'NO-PLAN-SCOPE-1: the scan puts a machine with a purchase plan outside the scope of this tool' {
    It 'an edition sold with a plan is blocked, with the plan as evidence: <Name>' -TestCases $planCases {
        $row = NpRow -Publisher $Ref.publisher -Offer $Ref.offer -Sku $Ref.sku -Os $Ref.os -PlanPublisher $Ref.plan.publisher -PlanProduct $Ref.plan.product -PlanName $Ref.plan.name
        InModuleScope VmMigrationFactory -Parameters @{ f = (NpKnown); row = $row; plan = $Ref.plan } {
            param($f, $row, $plan)
            $rec = Get-VmfAssessmentRecord -Vm $row -SkuEntry (NpSku) @f
            @($rec.blockers) | Should -Contain 'purchase-plan-out-of-scope'
            $rec.classification | Should -Be 'Blocked'
            $note = @($rec.notes | Where-Object { $_ -match 'purchase plan' })
            $note.Count | Should -Be 1
            $note[0] | Should -Match ([regex]::Escape("plan.publisher '$($plan.publisher)'"))
            $note[0] | Should -Match ([regex]::Escape("plan.product '$($plan.product)'"))
            $note[0] | Should -Match ([regex]::Escape("plan.name '$($plan.name)'"))
            $rec.planPublisher | Should -Be $plan.publisher
            $rec.planProduct | Should -Be $plan.product
        }
    }

    It 'a plan the scan read before this item, with no plan name, is a plan all the same' {
        $row = NpRow -PlanPublisher 'canonical' -PlanProduct '0001-com-ubuntu-pro-jammy' -NoPlanName
        InModuleScope VmMigrationFactory -Parameters @{ f = (NpKnown); row = $row } {
            param($f, $row)
            $rec = Get-VmfAssessmentRecord -Vm $row -SkuEntry (NpSku) @f
            @($rec.blockers) | Should -Contain 'purchase-plan-out-of-scope'
        }
    }

    It 'any one of the plan fields is a plan: <Name>' -TestCases @(
        @{ Name = 'publisher only'; A = @{ PlanPublisher = 'contoso' } }
        @{ Name = 'product only'; A = @{ PlanProduct = 'contoso-app' } }
        @{ Name = 'name only'; A = @{ PlanName = 'contoso-plan' } }
    ) {
        $row = NpRow @A
        InModuleScope VmMigrationFactory -Parameters @{ f = (NpKnown); row = $row } {
            param($f, $row)
            @((Get-VmfAssessmentRecord -Vm $row -SkuEntry (NpSku) @f).blockers) | Should -Contain 'purchase-plan-out-of-scope'
        }
    }

    It 'blank plan fields are no plan' {
        $row = NpRow -PlanPublisher ' ' -PlanProduct '' -PlanName ''
        InModuleScope VmMigrationFactory -Parameters @{ f = (NpKnown); row = $row } {
            param($f, $row)
            @((Get-VmfAssessmentRecord -Vm $row -SkuEntry (NpSku) @f).blockers) | Should -Not -Contain 'purchase-plan-out-of-scope'
        }
    }

    It 'a network virtual appliance with a plan keeps its own reason, once' {
        $row = NpRow -Publisher '' -Offer '' -Sku '' -PlanPublisher 'paloaltonetworks' -PlanProduct 'vmseries-flex' -PlanName 'byol' `
            -ImageId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/galleries/g/images/fw'
        InModuleScope VmMigrationFactory -Parameters @{ f = (NpKnown); row = $row } {
            param($f, $row)
            $rec = Get-VmfAssessmentRecord -Vm $row -SkuEntry (NpSku) @f
            @($rec.blockers) | Should -Contain 'nva-requires-parallel-deployment'
            @($rec.blockers) | Should -Not -Contain 'purchase-plan-out-of-scope'
        }
    }

    It 'a storage appliance found by its plan keeps its own reason, once' {
        $row = NpRow -Publisher '' -Offer '' -Sku '' -PlanPublisher 'purestorageinc1578960262525' -PlanProduct 'cloud_block_store_azure' -PlanName 'cbs' `
            -ImageId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/galleries/g/images/cbs'
        InModuleScope VmMigrationFactory -Parameters @{ f = (NpKnown); row = $row } {
            param($f, $row)
            $rec = Get-VmfAssessmentRecord -Vm $row -SkuEntry (NpSku) @f
            @($rec.blockers) | Should -Contain 'storage-appliance-needs-vendor'
            @($rec.blockers) | Should -Not -Contain 'purchase-plan-out-of-scope'
        }
    }

    It 'a machine in a managed application with a plan keeps its own reason, once' {
        $app = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-consumer/providers/Microsoft.Solutions/applications/contoso-app'
        $row = NpRow -PlanPublisher 'contoso' -PlanProduct 'contoso-app' -PlanName 'standard'
        InModuleScope VmMigrationFactory -Parameters @{ f = (NpKnown -Over @{ ResourceGroupOwners = @{ '00000000-0000-0000-0000-000000000000/rg-app' = $app } }); row = $row } {
            param($f, $row)
            $rec = Get-VmfAssessmentRecord -Vm $row -SkuEntry (NpSku) @f
            @($rec.blockers) | Should -Contain 'managed-application-needs-vendor'
            @($rec.blockers) | Should -Not -Contain 'purchase-plan-out-of-scope'
        }
    }

    It 'the blocker is outside the scope of this tool on every series, with words and a Microsoft page' {
        InModuleScope VmMigrationFactory { Get-VmfOutOfScopeBlockerCodes | Should -Contain 'purchase-plan-out-of-scope' }
        $r = $script:reasons.blockers.'purchase-plan-out-of-scope'
        $r | Should -Not -BeNullOrEmpty
        @($r.appliesTo) | Should -Be @('v5', 'v6', 'v7')
        $r.meaning | Should -Match 'Marketplace purchase plan'
        $r.whatToDo | Should -Match 'outside the scope of this tool'
        $r.docs.url | Should -Be 'https://learn.microsoft.com/en-us/azure/virtual-machines/marketplace-images'
    }

    It 'the target advice may give it as a reason' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw | ConvertFrom-Json
        @($schema.'$defs'.reason.enum) | Should -Contain 'purchase-plan-out-of-scope'
        $schema.properties.schemaVersion.const | Should -Be 34
        InModuleScope VmMigrationFactory { Get-VmfTargetAdviceSchemaVersion | Should -Be 34 }
    }

    It 'the scan reads the plan name from Resource Graph, and projects it' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Discovery.ps1')
        $code | Should -Match 'planName = tostring\(plan\.name\)'
        $code | Should -Match 'planPublisher, planProduct, planName,'
    }
}

Describe 'NO-PLAN-SCOPE-1: Checking stops a machine with a purchase plan untouched' {
    BeforeEach {
        $script:npRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-np-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:npRun; id = $script:npVm } {
            param($rp, $id)
            Initialize-VmfRun -RunPath $rp -RunId 'np' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'np' -VmId $id | Out-Null
        }
        $global:np = @{ read = [System.Collections.Generic.List[string]]::new() }
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine { }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { $global:np.read.Add(($DiskId -split '/')[-1]); 1 }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { throw 'no script runs here' }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { throw 'nothing is started here' }
    }
    AfterEach {
        Remove-Variable np -Scope Global -ErrorAction SilentlyContinue
        if ($script:npRun -and (Test-Path $script:npRun)) { [System.IO.Directory]::Delete($script:npRun, $true) }
    }

    It 'the machine''s plan stops it untouched, outside the scope of this tool, and names the plan: <Name>' -TestCases $planCases {
        $vm = NpLiveVm -Publisher $Ref.publisher -Offer $Ref.offer -PlanPublisher $Ref.plan.publisher -PlanProduct $Ref.plan.product -PlanName $Ref.plan.name
        InModuleScope VmMigrationFactory -Parameters @{ c = (NpCtx); v = $vm; plan = $Ref.plan } {
            param($c, $v, $plan)
            $stop = Get-VmfWorkloadScopeStop -Context $c -Vm $v
            $stop.Next | Should -Be 'NEEDS_DECISION'
            $stop.Reason | Should -Be 'purchasePlan'
            $stop.MachineState | Should -Be 'untouched'
            $stop.Detail | Should -Match ([regex]::Escape("plan.publisher '$($plan.publisher)'"))
            $stop.Detail | Should -Match ([regex]::Escape("plan.product '$($plan.product)'"))
            $stop.Detail | Should -Match ([regex]::Escape("plan.name '$($plan.name)'"))
            $stop.Detail | Should -Match 'outside the scope of this tool'
            $stop.Detail | Should -Match 'Nothing on the machine changed'
        }
        @($global:np.read).Count | Should -Be 0 -Because 'the machine is out of scope before the shared disk read'
    }

    It 'a machine with no plan goes on to the shared disk read' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (NpCtx); v = (NpLiveVm) } {
            param($c, $v)
            Get-VmfWorkloadScopeStop -Context $c -Vm $v | Should -BeNullOrEmpty
        }
        @($global:np.read) | Should -Be @('vm1-data0')
    }

    It 'a network virtual appliance with a plan keeps its own reason' {
        $vm = NpLiveVm -Publisher '' -Offer '' -PlanPublisher 'paloaltonetworks' -PlanProduct 'vmseries-flex' -PlanName 'byol'
        InModuleScope VmMigrationFactory -Parameters @{ c = (NpCtx); v = $vm } {
            param($c, $v)
            (Get-VmfWorkloadScopeStop -Context $c -Vm $v).Reason | Should -Be 'networkVirtualAppliance'
        }
    }

    It 'a storage appliance found by its plan keeps its own reason' {
        $vm = NpLiveVm -Publisher '' -Offer '' -PlanPublisher 'purestorageinc1578960262525' -PlanProduct 'cloud_block_store_azure' -PlanName 'cbs'
        InModuleScope VmMigrationFactory -Parameters @{ c = (NpCtx); v = $vm } {
            param($c, $v)
            (Get-VmfWorkloadScopeStop -Context $c -Vm $v).Reason | Should -Be 'storageAppliance'
        }
    }

    It 'the live verdict is the scan''s own rule' {
        InModuleScope VmMigrationFactory {
            $live = Get-VmfLivePurchasePlanVerdict -Vm (NpLiveVm -PlanPublisher 'suse' -PlanProduct 'sles-15-sp6-llc' -PlanName 'gen2')
            $scan = Get-VmfPurchasePlanEvidence -Plan ([pscustomobject]@{ publisher = 'suse'; product = 'sles-15-sp6-llc'; name = 'gen2' })
            $live.Words | Should -Be $scan.Words
            @($live.Evidence).Count | Should -Be 3
        }
    }

    It 'kill-resume: the check writes nothing, so the next worker stops the same way' {
        $vm = NpLiveVm -PlanPublisher 'canonical' -PlanProduct '0001-com-ubuntu-pro-jammy' -PlanName 'pro-22_04-lts'
        $before = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:npRun; id = $script:npVm } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id | ConvertTo-Json -Depth 20 }
        $first = InModuleScope VmMigrationFactory -Parameters @{ c = (NpCtx); v = $vm } { param($c, $v) Get-VmfWorkloadScopeStop -Context $c -Vm $v }
        $after = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:npRun; id = $script:npVm } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id | ConvertTo-Json -Depth 20 }
        $after | Should -Be $before
        $second = InModuleScope VmMigrationFactory -Parameters @{ c = (NpCtx); v = $vm } { param($c, $v) Get-VmfWorkloadScopeStop -Context $c -Vm $v }
        $second.Reason | Should -Be $first.Reason
        $second.Detail | Should -Be $first.Detail
    }

    Context 'the plan on the OS disk' {
        BeforeEach {
            $global:np.diskPlan = @{}
            Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts {
                $name = ($DiskId -split '/')[-1]
                [pscustomobject]@{ encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null
                    purchasePlan = $(if ($global:np.diskPlan.ContainsKey($name)) { $global:np.diskPlan[$name] } else { $null }) }
            }
            $script:npCapture = [pscustomobject]@{
                osDisk = [pscustomobject]@{ name = 'vm1-os'; managedDiskId = "$($script:npDisk)vm1-os" }
                dataDisks = @([pscustomobject]@{ lun = 0; name = 'vm1-data0'; managedDiskId = "$($script:npDisk)vm1-data0" })
            }
        }

        It 'an OS disk with a plan stops the machine untouched, from the disk read Checking already makes' {
            $global:np.diskPlan['vm1-os'] = [pscustomobject]@{ name = 'gen2'; publisher = 'suse'; product = 'sles-15-sp6-llc' }
            InModuleScope VmMigrationFactory -Parameters @{ c = (NpCtx); cap = $script:npCapture } {
                param($c, $cap)
                $stop = Add-VmfDiskEncryptionFacts -Context $c -Capture $cap
                $stop.Next | Should -Be 'NEEDS_DECISION'
                $stop.Reason | Should -Be 'purchasePlan'
                $stop.MachineState | Should -Be 'untouched'
                $stop.Detail | Should -Match "the OS disk 'vm1-os'"
                $stop.Detail | Should -Match "plan\.product 'sles-15-sp6-llc'"
                $stop.Detail | Should -Match 'outside the scope of this tool'
            }
        }

        It 'an OS disk with no plan goes on, and the capture records no plan' {
            InModuleScope VmMigrationFactory -Parameters @{ c = (NpCtx); cap = $script:npCapture } {
                param($c, $cap)
                Add-VmfDiskEncryptionFacts -Context $c -Capture $cap | Should -BeNullOrEmpty
                $cap.osDisk.encryptionType | Should -Be 'EncryptionAtRestWithPlatformKey'
                $cap.osDisk.PSObject.Properties.Name | Should -Not -Contain 'purchasePlan'
            }
        }

        It 'an encryption that cannot be read is said first: the machine stops once, for that' {
            $global:np.diskPlan['vm1-os'] = [pscustomobject]@{ name = 'gen2'; publisher = 'suse'; product = 'sles-15-sp6-llc' }
            $script:npCapture.dataDisks[0].managedDiskId = ''
            InModuleScope VmMigrationFactory -Parameters @{ c = (NpCtx); cap = $script:npCapture } {
                param($c, $cap)
                (Add-VmfDiskEncryptionFacts -Context $c -Capture $cap).Reason | Should -Be 'diskEncryptionNotKnown'
            }
        }
    }

    It 'the stop is in the stop table: outside the scope of this tool, and the machine untouched' {
        $r = @($script:stops.reasons | Where-Object code -EQ 'purchasePlan')
        $r.Count | Should -Be 1
        $r[0].retry | Should -Be 'outOfScope'
        $r[0].machine | Should -Be 'untouched'
        $r[0].title | Should -Match '\(not in scope\)$'
        $r[0].meaning | Should -Match 'Marketplace purchase plan'
        $r[0].meaning | Should -Match 'plan\.publisher, plan\.product and plan\.name'
        $r[0].meaning | Should -Match 'outside the scope of this tool'
        $r[0].meaning | Should -Match 'Nothing on the machine was changed'
    }
}

Describe 'NO-PLAN-SCOPE-1: the support matrix says it' {
    It 'the Linux distributions stay Supported, and the page names their editions with a plan as outside the scope of this tool' {
        $page = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'support-matrix.md') -Raw
        foreach ($row in '| Ubuntu | Canonical | Supported |', '| Red Hat Enterprise Linux | RedHat | Supported |', '| SUSE Linux Enterprise Server | SUSE | Supported |', '| Oracle Linux | Oracle | Supported |') {
            $page | Should -Match ([regex]::Escape($row))
        }
        $page | Should -Match 'Some editions of these distributions have a Marketplace purchase plan: Ubuntu Pro, RHEL BYOS and the SUSE offers with a name that ends in -llc\. A machine with a purchase plan is outside the scope of this tool'
        $page | Should -Match 'A Windows machine with a Marketplace purchase plan, for example from a Windows Server preview image, is outside the scope of this tool'
        $page | Should -Match '\| Machine with a Marketplace purchase plan \| .* \| Not supported \| \[Microsoft: Marketplace purchase plan information\]\(https://learn\.microsoft\.com/en-us/azure/virtual-machines/marketplace-images\) \|'
    }
}

Describe 'NO-PLAN-SCOPE-1: a rebuild sends no purchase plan, and the capture records none' {
    It 'the carry-over is gone: <Name>' -TestCases @(
        @{ Name = 'Get-VmfRebuildPurchasePlan' }
        @{ Name = 'New-VmfVmPlanModel' }
        @{ Name = 'Set-VmfCapturePlanFromDisk' }
        @{ Name = 'ConvertTo-VmfCapturedPlan' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ n = $Name } { param($n) Get-Command $n -ErrorAction SilentlyContinue | Should -BeNullOrEmpty }
    }

    It 'nothing in the module sets a plan on a machine definition' {
        foreach ($file in Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter '*.ps1' -Recurse) {
            $code = Get-VmfCodeOnly -Path $file.FullName
            $code | Should -Not -Match '(?i)\$config\.Plan\b' -Because $file.Name
            $code | Should -Not -Match 'Models\.Plan\]' -Because $file.Name
        }
    }

    # REBUILD-REMOVE-ENGINE-1: the capture field list was the list a rebuild put back, and went with the rebuild.
    It 'the state format names no purchase plan, and the sample holds none' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $schema.properties.schemaVersion.const | Should -Be 51
        InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion | Should -Be 51 }
        $schema.properties.captured.properties.vmConfig.properties.PSObject.Properties.Name | Should -Not -Contain 'purchasePlan' -Because 'no record of this version holds one (OLD-STATE-READERS-FINISH-1)'
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw | ConvertFrom-Json -Depth 40
        $sample.captured.vmConfig.PSObject.Properties.Name | Should -Not -Contain 'purchasePlan'
        $sample.captured.vmConfig.osDisk.PSObject.Properties.Name | Should -Not -Contain 'purchasePlan'
    }
}
