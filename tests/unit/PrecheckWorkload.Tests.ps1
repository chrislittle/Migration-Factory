#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PRECHECK-WORKLOAD-1, 2026-11-01. DETECT-PATTERNS-1 refuses a storage or
# backup appliance and a machine with a shared disk at the scan (assessment
# version 4). A plan made from an older assessment has neither blocker, and
# nothing at Checking asked again - so the engine stopped a cluster node on a
# shared disk, or a vendor's appliance, as if it were alone. A disk can also
# become shared after the scan: an administrator raises its maxShares the day
# before the wave.
#
# So Checking asks Azure again, in the one workload function that PRECHECK
# calls as soon as it has read the machine (Get-VmfWorkloadScopeStop), beside
# the other out-of-scope stops - before any stop a person can accept, any
# RunCommand and the start for the cluster check:
#   - the image, the Marketplace plan and the gallery image of the machine as
#     Azure has it now, judged with the scan's own rule (Test-VmfStorageAppliance);
#   - the maxShares of each data disk, read with the engine's own shared disk
#     read (Get-VmfDiskShareCount), the one the put-back uses.
# Both stop untouched, outside the scope of this tool. Nothing is started.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:pwVm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm'
    $script:pwDisk = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/disks/'

    # The machine as Get-VmfVmConfig returns it (the Get-AzVM shape).
    function Global:PwVm {
        param(
            [string[]]$Disks = @('vm-data0', 'vm-data1'),
            [string]$Publisher = 'Canonical', [string]$Offer = '0001-com-ubuntu-server-jammy',
            [string]$ImageId = '', [string]$CommunityId = '', [string]$SharedId = '',
            [string]$PlanPublisher = '', [string]$PlanProduct = '',
            [switch]$NoImage
        )
        $lun = 0
        [pscustomobject]@{
            Id = $script:pwVm; Name = 'vm'
            Plan = $(if ($PlanPublisher) { [pscustomobject]@{ Publisher = $PlanPublisher; Product = $PlanProduct; Name = 'plan1' } } else { $null })
            StorageProfile = [pscustomobject]@{
                ImageReference = $(if ($NoImage) { $null } else {
                        [pscustomobject]@{ Publisher = $Publisher; Offer = $Offer; Sku = 'sku1'; Id = $ImageId
                                           CommunityGalleryImageId = $CommunityId; SharedGalleryImageId = $SharedId } })
                DataDisks = @(foreach ($d in $Disks) {
                        [pscustomobject]@{ Lun = $lun; Name = $d; ManagedDisk = [pscustomobject]@{ Id = "$($script:pwDisk)$d" } }
                        $lun++
                    })
            }
        }
    }
    function Global:PwCtx([string]$Os = 'Windows') {
        @{ Plan = [pscustomobject]@{ assessment = [pscustomobject]@{ os = $Os } }
           Rg = 'rg'; VmName = 'vm'; VmId = $script:pwVm; RunPath = $script:pwRun }
    }
    function Global:PwAlone {
        [pscustomobject]@{ schema = 'vmf.guest/4'; script = 'Test-ClusterNode.ps1'; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
            facts = [pscustomobject]@{ os = 'Windows'; clusterService = 'absent'; clusterKey = 'no'; sqlHadr = 'no' } }
    }
    function Global:PwPowerRecord {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:pwRun; id = $script:pwVm } {
            param($rp, $id)
            $d = Read-VmfStateDoc -RunPath $rp -VmId $id
            if ($d.captured -and $d.captured.PSObject.Properties['clusterCheckPower']) { $d.captured.clusterCheckPower } else { $null }
        }
    }
}

AfterAll {
    Remove-Item 'function:\PwVm', 'function:\PwCtx', 'function:\PwAlone', 'function:\PwPowerRecord' -ErrorAction SilentlyContinue
}

Describe 'PRECHECK-WORKLOAD-1: a shared disk and a storage appliance stop at Checking, whatever assessment the plan came from' {
    BeforeEach {
        $script:pwRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pw-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:pwRun; id = $script:pwVm } {
            param($rp, $id)
            Initialize-VmfRun -RunPath $rp -RunId 'pw' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'pw' -VmId $id | Out-Null
        }
        # disk name -> maxShares, or a scriptblock that throws.
        $global:pw = @{ shares = @{}; readFails = $null; ran = [System.Collections.Generic.List[string]]::new(); read = [System.Collections.Generic.List[string]]::new() }
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine { }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount {
            $name = ($DiskId -split '/')[-1]
            $global:pw.read.Add($name)
            if ($global:pw.readFails) { throw $global:pw.readFails }
            if ($global:pw.shares.ContainsKey($name)) { $global:pw.shares[$name] } else { 1 }
        }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { $global:pw.ran.Add($ScriptName); PwAlone }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmPoweredOff { }
    }
    AfterEach {
        Remove-Variable pw -Scope Global -ErrorAction SilentlyContinue
        if ($script:pwRun -and (Test-Path $script:pwRun)) { [System.IO.Directory]::Delete($script:pwRun, $true) }
    }

    Context 'a shared disk' {
        It 'a running machine with a shared data disk stops untouched, out of scope, and names the disk - no script runs in it' {
            $global:pw.shares['vm-data1'] = 2
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = (PwVm) } {
                $stop = Get-VmfWorkloadScopeStop -Context $c -Vm $v
                $stop.Next | Should -Be 'NEEDS_DECISION'
                $stop.Reason | Should -Be 'sharedDisk'
                $stop.MachineState | Should -Be 'untouched'
                $stop.Detail | Should -Match "'vm-data1' on LUN 1 has maxShares 2"
                $stop.Detail | Should -Match 'Nothing on the machine changed'
                $stop.Detail | Should -Not -Match 'vm-data0'
            }
            @($global:pw.ran).Count | Should -Be 0 -Because 'a machine with a shared disk is out of scope before the cluster check'
        }

        It 'a machine with a shared disk is never started' {
            $global:pw.shares['vm-data0'] = 3
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = (PwVm) } {
                (Get-VmfWorkloadScopeStop -Context $c -Vm $v).Reason | Should -Be 'sharedDisk'
                Should -Invoke Start-VmfVm -Times 0 -Exactly
                Should -Invoke Stop-VmfVmDeallocated -Times 0 -Exactly
            }
            PwPowerRecord | Should -BeNullOrEmpty -Because 'nothing was started, so nothing is owed'
        }

        It 'every data disk is read by its id, and with none shared the machine goes on - no script runs here' {
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = (PwVm) } {
                Get-VmfWorkloadScopeStop -Context $c -Vm $v | Should -BeNullOrEmpty
            }
            @($global:pw.read) | Should -Be @('vm-data0', 'vm-data1')
            @($global:pw.ran).Count | Should -Be 0
        }

        It 'maxShares 1 on every disk is not a shared disk' {
            $global:pw.shares['vm-data0'] = 1
            $global:pw.shares['vm-data1'] = 1
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = (PwVm) } {
                Get-VmfWorkloadScopeStop -Context $c -Vm $v | Should -BeNullOrEmpty
            }
        }

        It 'a machine with no data disk reads no disk' {
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = (PwVm -Disks @()) } {
                Get-VmfWorkloadScopeStop -Context $c -Vm $v | Should -BeNullOrEmpty
            }
            @($global:pw.read).Count | Should -Be 0
        }

        It 'a data disk with no managed disk id is not read: only a managed disk can be a shared disk' {
            $v = PwVm -Disks @('vm-data0')
            $v.StorageProfile.DataDisks += [pscustomobject]@{ Lun = 1; Name = 'vm-vhd'; ManagedDisk = $null }
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = $v } {
                Get-VmfWorkloadScopeStop -Context $c -Vm $v | Should -BeNullOrEmpty
            }
            @($global:pw.read) | Should -Be @('vm-data0')
        }

        It 'a read that fails goes up to the step, never a pass, and nothing is started' {
            $global:pw.readFails = 'Reading disk failed with 500'
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = (PwVm) } {
                { Get-VmfWorkloadScopeStop -Context $c -Vm $v } | Should -Throw '*failed with 500*'
                Should -Invoke Start-VmfVm -Times 0 -Exactly
            }
            @($global:pw.ran).Count | Should -Be 0
        }


        It 'kill-resume: a worker killed during the disk read touches nothing; the next worker reads again and stops untouched' {
            $global:pw.shares['vm-data1'] = 2
            $global:pw.readFails = 'Lease lost - abandon this VM'
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = (PwVm) } {
                { Get-VmfWorkloadScopeStop -Context $c -Vm $v } | Should -Throw '*abandon this VM*'
            }
            PwPowerRecord | Should -BeNullOrEmpty
            $global:pw.readFails = $null
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = (PwVm) } {
                $stop = Get-VmfWorkloadScopeStop -Context $c -Vm $v
                $stop.Reason | Should -Be 'sharedDisk'
                $stop.MachineState | Should -Be 'untouched'
                Should -Invoke Start-VmfVm -Times 0 -Exactly
            }
            @($global:pw.ran).Count | Should -Be 0
            PwPowerRecord | Should -BeNullOrEmpty
        }
    }

    Context 'a storage or backup appliance' {
        It 'found by its image (<Name>): stops untouched, out of scope, names the vendor and the Azure fields, and reads no disk' -TestCases @(
            @{ Name = 'Marketplace image'; VmArgs = @{ Publisher = 'rubrik-inc'; Offer = 'rubrik-cloud-cluster' }; Field = 'imageReference.offer' }
            @{ Name = 'Marketplace plan'; VmArgs = @{ Publisher = ''; Offer = ''; ImageId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/galleries/g/images/i'; PlanPublisher = 'rubrik-inc'; PlanProduct = 'rubrik-cloud-cluster' }; Field = 'plan.product' }
            @{ Name = 'community gallery'; VmArgs = @{ Publisher = ''; Offer = ''; CommunityId = '/communityGalleries/WekaIO-0123/images/weka/versions/1.0.0' }; Field = 'imageReference.communityGalleryImageId' }
        ) {
            $vm = PwVm @VmArgs
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = $vm; f = $Field } {
                $stop = Get-VmfWorkloadScopeStop -Context $c -Vm $v
                $stop.Next | Should -Be 'NEEDS_DECISION'
                $stop.Reason | Should -Be 'storageAppliance'
                $stop.MachineState | Should -Be 'untouched'
                $stop.Detail | Should -Match ([regex]::Escape($f))
                $stop.Detail | Should -Match 'Nothing on the machine changed'
                Should -Invoke Start-VmfVm -Times 0 -Exactly
            }
            @($global:pw.read).Count | Should -Be 0
            @($global:pw.ran).Count | Should -Be 0
        }

        It 'the vendor is named' {
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = (PwVm -Publisher 'rubrik-inc' -Offer 'rubrik-cloud-cluster') } {
                (Get-VmfWorkloadScopeStop -Context $c -Vm $v).Detail | Should -Match 'Rubrik'
            }
        }

        It 'a shared gallery image is read as a gallery image too' {
            InModuleScope VmMigrationFactory {
                $v = PwVm -Publisher '' -Offer '' -SharedId '/communityGalleries/WekaIO-0123/images/weka'
                (Get-VmfLiveApplianceVerdict -Vm $v).Evidence[0].field | Should -Be 'imageReference.sharedGalleryImageId'
            }
        }

        It 'the publisher alone is never evidence: a Veeam image that is not an appliance goes on' {
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = (PwVm -Publisher 'veeam' -Offer 'office365backup') } {
                Get-VmfWorkloadScopeStop -Context $c -Vm $v | Should -BeNullOrEmpty
            }
        }

        It 'a machine with no image record (a specialized disk) is not called an appliance from nothing' {
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = (PwVm -NoImage) } {
                Get-VmfWorkloadScopeStop -Context $c -Vm $v | Should -BeNullOrEmpty
            }
        }

        It 'the live verdict is the scan''s own rule: the same machine gives the same answer both ways' {
            InModuleScope VmMigrationFactory {
                $v = PwVm -Publisher 'rubrik-inc' -Offer 'rubrik-cloud-cluster'
                $live = Get-VmfLiveApplianceVerdict -Vm $v
                $scan = Test-VmfStorageAppliance -ImagePublisher 'rubrik-inc' -ImageOffer 'rubrik-cloud-cluster'
                $live.IsAppliance | Should -BeTrue
                $live.Vendor | Should -Be $scan.Vendor
                $live.Sign | Should -Be $scan.Sign
            }
        }
    }

    # NVA-PRECHECK-1, 2026-11-02. The scan refuses a network virtual appliance
    # (WORKLOAD-1), and since NVA-PLAN-1 it finds one by its Marketplace
    # purchase plan too. A plan made from an assessment before NVA-PLAN-1 has
    # no blocker on a gallery appliance, so Checking asks Azure again, with
    # the scan's own rule (Test-VmfNvaImage), beside the appliance check.
    Context 'a network virtual appliance' {
        It 'a gallery appliance with a Marketplace plan stops untouched, out of scope, names plan.publisher and plan.product, and nothing runs' {
            $vm = PwVm -Publisher '' -Offer '' -ImageId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/galleries/g/images/fw' `
                -PlanPublisher 'paloaltonetworks' -PlanProduct 'vmseries-flex'
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = $vm } {
                $stop = Get-VmfWorkloadScopeStop -Context $c -Vm $v
                $stop.Next | Should -Be 'NEEDS_DECISION'
                $stop.Reason | Should -Be 'networkVirtualAppliance'
                $stop.MachineState | Should -Be 'untouched'
                $stop.Detail | Should -Match "plan\.publisher 'paloaltonetworks'"
                $stop.Detail | Should -Match "plan\.product 'vmseries-flex'"
                $stop.Detail | Should -Match 'Nothing on the machine changed'
                Should -Invoke Start-VmfVm -Times 0 -Exactly
                Should -Invoke Stop-VmfVmDeallocated -Times 0 -Exactly
            }
            @($global:pw.read).Count | Should -Be 0 -Because 'an appliance is out of scope before the shared disk read'
            @($global:pw.ran).Count | Should -Be 0
            PwPowerRecord | Should -BeNullOrEmpty
        }

        It 'a Marketplace image appliance stops and names imageReference.publisher and imageReference.offer' {
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = (PwVm -Publisher 'fortinet' -Offer 'fortinet_fortigate-vm_v5') } {
                $stop = Get-VmfWorkloadScopeStop -Context $c -Vm $v
                $stop.Reason | Should -Be 'networkVirtualAppliance'
                $stop.Detail | Should -Match "imageReference\.publisher 'fortinet'"
                $stop.Detail | Should -Match "imageReference\.offer 'fortinet_fortigate-vm_v5'"
            }
        }

        It 'an ordinary machine is not an appliance: <Name>' -TestCases @(
            @{ Name = 'a Marketplace image'; VmArgs = @{} }
            @{ Name = 'a gallery image with no plan'; VmArgs = @{ Publisher = ''; Offer = ''; ImageId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/galleries/g/images/web' } }

            @{ Name = 'a specialized disk with no image'; VmArgs = @{ NoImage = $true } }
        ) {
            $vm = PwVm @VmArgs
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = $vm } {
                Get-VmfWorkloadScopeStop -Context $c -Vm $v | Should -BeNullOrEmpty
            }
            @($global:pw.read) | Should -Be @('vm-data0', 'vm-data1') -Because 'an ordinary machine goes on to the shared disk read'
        }

        It 'NO-PLAN-SCOPE-1: a gallery image with a plan that is not an appliance stops for its plan, not as an appliance' {
            $vm = PwVm -Publisher '' -Offer '' -ImageId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/galleries/g/images/web' -PlanPublisher 'canonical' -PlanProduct 'ubuntu-pro'
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = $vm } {
                (Get-VmfLiveNvaVerdict -Vm $v).IsNva | Should -BeFalse
                (Get-VmfWorkloadScopeStop -Context $c -Vm $v).Reason | Should -Be 'purchasePlan'
            }
            @($global:pw.read).Count | Should -Be 0
        }

        It 'a plan on both lists (NetApp) stops once, with the network virtual appliance reason, as at the scan' {
            $vm = PwVm -Publisher '' -Offer '' -ImageId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/galleries/g/images/ontap' `
                -PlanPublisher 'netapp' -PlanProduct 'netapp-ontap-cloud'
            InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = $vm } {
                (Get-VmfLiveApplianceVerdict -Vm $v).IsAppliance | Should -BeTrue -Because 'NetApp is on the storage appliance list too'
                (Get-VmfWorkloadScopeStop -Context $c -Vm $v).Reason | Should -Be 'networkVirtualAppliance'
            }
        }

        It 'the live verdict is the scan''s own rule: the same machine gives the same answer both ways' {
            InModuleScope VmMigrationFactory {
                $v = PwVm -Publisher '' -Offer '' -PlanPublisher ' PaloAltoNetworks ' -PlanProduct 'VMSeries-Flex'
                $live = Get-VmfLiveNvaVerdict -Vm $v
                $scan = Test-VmfNvaImage -Publisher '' -Offer '' -PlanPublisher ' PaloAltoNetworks ' -PlanProduct 'VMSeries-Flex'
                $live.IsNva | Should -BeTrue
                $live.Sign | Should -Be 'plan'
                $live.Sign | Should -Be $scan.Sign
                $live.Detail | Should -Be $scan.Detail
            }
        }

        It 'the image is read from the image and the plan from the plan, never crossed' {
            InModuleScope VmMigrationFactory {
                # An ordinary image with an appliance plan: the plan decides.
                $v = PwVm -Publisher 'Canonical' -Offer 'ubuntu-server' -PlanPublisher 'paloaltonetworks' -PlanProduct 'vmseries-flex'
                (Get-VmfLiveNvaVerdict -Vm $v).Sign | Should -Be 'plan'
                # An appliance image with no plan: the image decides.
                $v = PwVm -Publisher 'paloaltonetworks' -Offer 'vmseries-flex'
                (Get-VmfLiveNvaVerdict -Vm $v).Sign | Should -Be 'image'
                # A plan publisher alone is not a plan.
                $v = PwVm -Publisher '' -Offer '' -PlanPublisher 'paloaltonetworks' -PlanProduct ''
                (Get-VmfLiveNvaVerdict -Vm $v).IsNva | Should -BeFalse
            }
        }

        It 'kill-resume: Checking writes nothing for it, so a worker killed after it leaves no record, and the next worker stops the same way' {
            $vm = PwVm -Publisher '' -Offer '' -PlanPublisher 'paloaltonetworks' -PlanProduct 'vmseries-flex'
            $before = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:pwRun; id = $script:pwVm } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id | ConvertTo-Json -Depth 20 }
            $first = InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = $vm } { Get-VmfWorkloadScopeStop -Context $c -Vm $v }
            $after = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:pwRun; id = $script:pwVm } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id | ConvertTo-Json -Depth 20 }
            $after | Should -Be $before -Because 'the check only reads Azure, so a kill at any point leaves the state document as it was'
            $second = InModuleScope VmMigrationFactory -Parameters @{ c = (PwCtx); v = $vm } { Get-VmfWorkloadScopeStop -Context $c -Vm $v }
            $second.Reason | Should -Be $first.Reason
            $second.Detail | Should -Be $first.Detail
            $second.MachineState | Should -Be 'untouched'
        }
    }
}

Describe 'PRECHECK-WORKLOAD-1: where the checks run, and the words' {
    BeforeAll {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $start = $code.IndexOf('function Invoke-VmfStepPrecheck')
        $script:pre = $code.Substring($start, $code.IndexOf('function Get-VmfSafetyAttempt') - $start)
        $script:scopeAt = $script:pre.IndexOf('Get-VmfWorkloadScopeStop')
    }

    It 'PRECHECK asks it once, with the machine it read' {
        ([regex]::Matches($script:pre, 'Get-VmfWorkloadScopeStop')).Count | Should -Be 1
        $script:pre | Should -Match 'Get-VmfWorkloadScopeStop -Context \$Context -Vm \$vm\s'
        $script:scopeAt | Should -BeGreaterThan $script:pre.IndexOf("-Name 'getVm'")
    }

    It 'it is asked with the other out-of-scope stops, right after the 32 data disk stop' {
        $script:scopeAt | Should -BeGreaterThan $script:pre.IndexOf('$ownDisks = Get-VmfDataDiskScopeDetail')
        $script:scopeAt | Should -BeLessThan $script:pre.IndexOf('Get-VmfRetirementWarning -Size $ownSize')
    }

    It 'it comes before every stop a person can accept or fix after the machine is read, and before any RunCommand: <Name>' -TestCases @(
        # PRECHECK-EXT-READ-1: the read moved into Read-VmfPrecheckExtensions, which carries its stop.
        @{ Name = 'the extension read'; Text = 'Read-VmfPrecheckExtensions' }
        @{ Name = 'the network interface and data disk count of the target'; Text = "Reason = 'targetTooFewNics'" }
        @{ Name = 'instant access disks'; Text = 'Add-VmfInstantAccessDiskFacts' }
        @{ Name = 'disk encryption'; Text = 'Add-VmfDiskEncryptionFacts' }
        @{ Name = 'the put-back size'; Text = 'Test-VmfPutBackSizeFits' }
        @{ Name = 'accelerated networking on the target'; Text = 'Test-VmfTargetAcceleratedNicsFit' }
        @{ Name = 'linked permissions'; Text = 'Test-VmfNicLinkedPermissions' }
        @{ Name = 'disk encryption set permissions'; Text = 'Test-VmfDiskEncryptionSetPermissions' }
        @{ Name = 'capacity reservation permissions'; Text = 'Test-VmfReservationJoinPermissions' }
        @{ Name = 'user-assigned identity permissions'; Text = 'Test-VmfIdentityAssignPermissions' }
        @{ Name = 'the disk type change'; Text = 'Test-VmfDiskUpgradeReady' }
        @{ Name = 'accelerated networking required'; Text = "Reason = 'acceleratedNetworkingRequired'" }
        @{ Name = 'the files on the temporary disk (a RunCommand)'; Text = 'Get-VmfTempDiskContentStop' }
        @{ Name = 'the cluster check (a RunCommand, and a start)'; Text = 'Get-VmfWorkloadCheckStop' }
    ) {
        $at = $script:pre.IndexOf($Text)
        $at | Should -BeGreaterThan 0 -Because "PRECHECK still has $Text"
        $script:scopeAt | Should -BeLessThan $at
    }

    It 'it reads Azure only: no RunCommand, no start, no stop and no write in it' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'WorkloadCheck.ps1')
        $from = $code.IndexOf('function Get-VmfLiveApplianceVerdict')
        $body = $code.Substring($from, $code.IndexOf('function Get-VmfWorkloadCheckStop') - $from)
        $body | Should -Match 'function Get-VmfWorkloadScopeStop'
        $body | Should -Not -Match 'Invoke-VmfGuestScriptOnVm|Start-VmfVm|Stop-VmfVm|Save-VmfCapturedFacts|Write-VmfStateDoc'
    }

    It 'the machine is a required input' {
        InModuleScope VmMigrationFactory {
            $vmParam = (Get-Command Get-VmfWorkloadScopeStop).Parameters['Vm']
            $vmParam | Should -Not -BeNullOrEmpty
            @($vmParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ParameterAttribute] })[0].Mandatory | Should -BeTrue
        }
    }

    It 'every stop is in the stop table: outside the scope of this tool, and the machine untouched' {
        $stops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
        foreach ($code in 'sharedDisk', 'storageAppliance', 'networkVirtualAppliance', 'purchasePlan') {
            $r = @($stops.reasons | Where-Object code -EQ $code)
            $r.Count | Should -Be 1 -Because $code
            $r[0].retry | Should -Be 'outOfScope'
            $r[0].machine | Should -Be 'untouched'
            $r[0].meaning | Should -Match 'Nothing on the machine was changed'
            $r[0].title | Should -Match '\(not in scope\)$'
        }
        $nva = @($stops.reasons | Where-Object code -EQ 'networkVirtualAppliance')[0]
        $nva.meaning | Should -Match 'Marketplace purchase plan'
        $nva.meaning | Should -Match 'plan\.publisher and plan\.product'
        $nva.meaning | Should -Match 'the traffic stops'
    }
}