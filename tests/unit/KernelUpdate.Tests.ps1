#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MANA-LINUX-KERNEL-1, 2026-10-04: a Linux machine whose kernel
# has no MANA driver can have the product UPDATE THE KERNEL during the move, if
# a person chose that for the machine on the targets step.
#
#   * The choice: one default for the migration (Stop) and a change per machine,
#     saved with the targets (target-choices v5), offered only for a Linux
#     machine whose target can give MANA.
#   * The plan: carried as the machine's OWN decision (plan-entry v19
#     onDriverBelowFloor = updateKernel, with a decisions record), so a wave
#     save never writes over it.
#   * The move: in GUEST_PREP, after the pristine copy - kernel-update.sh, a
#     stop and start, the guest agent, mana-check.sh again. Any failure puts
#     the machine back from the pristine copy, with the rollback every failure
#     uses. A release Microsoft does not list stops as before: an update does
#     not change the release.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:work = New-VmfTestTemp -Prefix 'kern'
    $script:schemas = Join-Path $script:repoRoot 'schemas'
}
AfterAll { Remove-VmfTestTemp }

Describe 'MANA-LINUX-KERNEL-1: the contracts' {
    It 'plan-entry v19 offers updateKernel (v33: proceed left), and the lever table never writes updateKernel' {
        $schema = Get-Content (Join-Path $script:schemas 'plan-entry.schema.json') -Raw | ConvertFrom-Json
        # WAVE-AN-NAMES-1 moved the format to v20; updateKernel is still offered.
        $schema.properties.schemaVersion.const | Should -BeGreaterOrEqual 19
        @($schema.properties.policy.properties.onDriverBelowFloor.enum) | Should -Be @('stop', 'updateKernel')
        InModuleScope VmMigrationFactory {
            # A decision may not write updateKernel - it is a choice made per
            # machine on the targets step. WAVE-KERNEL-LINE-1: and a wave save
            # writes no kernel setting at all.
            (Test-VmfPolicyOverride -Override @{ onDriverBelowFloor = 'updateKernel' }).Ok | Should -BeFalse
            { ConvertTo-VmfWaveLayout -Layout @{ waves = @(@{ name = 'w1'; vmIds = @(); onDriverBelowFloor = 'updateKernel' }) } } |
                Should -Throw '*A wave has no kernel choice*'
        }
    }

    It 'target-choices v5 declares the default and the choice per machine' {
        $schema = Get-Content (Join-Path $script:schemas 'target-choices.schema.json') -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be 9   # TARGETS-NO-LIST-1; v5 added the kernel choice
        @($schema.properties.kernelDefault.enum) | Should -Be @('stop')   # KERNEL-DEFAULT-EARLIER-1
        @($schema.properties.choices.items.properties.kernel.enum) | Should -Contain 'update'
    }

    # PREP-ROLLBACK-1 took v19 (the rollback checkpoint), SAFETY-ULTRA-1 v20
    # (the Premium SSD v2 and Ultra Disk record) and SAFETY-CMK-1 v21 (the
    # encryption of every disk); v21 keeps the record.
    It 'vm-state v18 declares the record, and the store writes v21, which keeps it' {
        $schema = Get-Content (Join-Path $script:schemas 'vm-state.schema.json') -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be 51
        @($schema.properties.captured.properties.kernelUpdate.properties.result.enum) | Should -Be @('running', 'updated', 'failed', 'stopped')
        InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion | Should -Be 51 }
    }

    It 'the stop has its own reason: the machine is put back, and a retry after the fix works' {
        InModuleScope VmMigrationFactory {
            $g = Get-VmfStopGuidance -Code 'kernelUpdateFailed'
            $g.machine | Should -Be 'restored'
            $g.retry | Should -Be 'afterFix'
        }
    }

    It 'RHEL-PINNED-KERNEL-ADVICE-1: no newer kernel in the repositories never sends the person back to Update the kernel' {
        # Lab 2026-11-08: Red Hat 9.4 from RedHat:RHEL:94_gen2 (EUS
        # repositories, held to 9.4) stopped with no newer kernel, and the
        # advice said to choose Update the kernel - the choice that was made.
        InModuleScope VmMigrationFactory {
            $g = Get-VmfStopGuidance -Code 'kernelNotInRepositories'
            $g | Should -Not -BeNullOrEmpty
            $g.machine | Should -Be 'untouched'
            $g.retry | Should -Be 'afterFix'
            $g.PSObject.Properties['decide'] | Should -BeNullOrEmpty -Because 'a kernel with no MANA driver has nothing to accept (AN-PROCEED-NETVSC-1)'
            $g.whatToDo | Should -Not -Match '(?i)choose Update the kernel'
            # The ways out the product supports, and Microsoft's own page for the repositories.
            $g.whatToDo | Should -Match 'non-EUS repositories'
            $g.whatToDo | Should -Match 'Red Hat Update Infrastructure'
            $g.whatToDo | Should -Match 'choose an AMD v5 size on the Choose each target step'
            $g.whatToDo | Should -Match '(?i)leave the machine out'
            $g.meaning | Should -Match 'image for one minor release'
        }
    }

    # KERNEL-CHOICE-STOP-ADVICE-1: the two other untouched stops that come
    # after a person chose Update the kernel. They used driverBelowFloor, whose
    # advice begins "Choose Update the kernel" - the choice the machine has.
    It 'KERNEL-CHOICE-STOP-ADVICE-1: <Code> never sends the person back to Update the kernel' -TestCases @(
        # The approved words (2026-11-11). The card already shows
        # "Nothing on this machine was changed." and the detail.
        # KERNEL-OFFER-EDGES-1: the stop also comes with Stop and ask now
        # (driverBelowFloor's advice would offer Update the kernel), so the
        # meaning no longer says the choice was made (the words wait for approval).
        @{ Code = 'kernelUpdateNoRule'
            Title = 'The product cannot update this kernel'
            Meaning = 'The product updates only the Azure kernel. On Ubuntu, the Azure kernel is linux-azure. This machine runs a different kernel. Update the kernel cannot change this kernel. The product did not change the machine.'
            WhatToDo = 'Install a kernel with a MANA driver. For an AMD machine, you can choose AMD v5 instead. Or leave the machine out.' }
        # KERNEL-OFFER-EDGES-1: an update that cannot reach the minimum (HELD).
        @{ Code = 'kernelUpdateCannotReachMinimum'
            Title = 'An update cannot reach the kernel version that Microsoft lists for MANA'
            Meaning = 'The kernel is below the minimum version that Microsoft lists for MANA. On this machine, an update cannot install a kernel at that version. The cause is the repositories, the kernel flavour or the releasever setting. The product did not change the machine. The stop names the cause.'
            WhatToDo = 'Read the cause in the stop. Install a kernel at the minimum version with the steps from the maker of the distribution. For an AMD machine, you can choose an AMD v5 size on the Choose each target step, then plan again. AMD v5 does not use MANA. Or leave the machine out.' }
        @{ Code = 'releaseNotListedForMana'
            Title = 'Microsoft does not list this Linux release for MANA'
            Meaning = 'A kernel update does not change the release, so the product did not update the kernel.'
            WhatToDo = 'Upgrade to the release that the stop names. For an AMD machine, you can choose AMD v5 instead. Or leave the machine out.' }
        # ORACLE-UEK7-KERNEL-STOP-1: a UEK kernel Microsoft does not list. It
        # names the kernel, not the release (the release is listed).
        # ORACLE-UEK-UPDATE-1: the product now installs UEK R8 when the UEK R8
        # repository is enabled, so the meaning says that, and the detail says
        # why it did not (the words wait for approval).
        @{ Code = 'uekKernelNotListedForMana'
            Title = 'Microsoft does not list this UEK kernel for MANA'
            Meaning = 'Microsoft lists UEK R8 for MANA, and not this UEK kernel. The product installs UEK R8 only when the UEK R8 repository of the release is enabled on the machine. The product does not change repositories. The stop says why the product did not update the kernel.'
            WhatToDo = 'Do what the stop says, with the steps from Oracle. For an AMD machine, you can choose AMD v5 instead. Or leave the machine out.' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ Code = $Code; Title = $Title; Meaning = $Meaning; WhatToDo = $WhatToDo } {
            param($Code, $Title, $Meaning, $WhatToDo)
            $g = Get-VmfStopGuidance -Code $Code
            $g | Should -Not -BeNullOrEmpty
            $g.code | Should -Be $Code
            $g.machine | Should -Be 'untouched'
            $g.retry | Should -Be 'afterFix'
            $g.PSObject.Properties['decide'] | Should -BeNullOrEmpty -Because 'a kernel with no MANA driver has nothing to accept (AN-PROCEED-NETVSC-1)'
            $g.title | Should -BeExactly $Title
            $g.meaning | Should -BeExactly $Meaning
            $g.whatToDo | Should -BeExactly $WhatToDo
            $g.whatToDo | Should -Not -Match '(?i)Update the kernel'
        }
    }
    It 'the migration note covers all three' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match 'plan-entry v18 -> v19'
        $notes | Should -Match 'target-choices v4 -> v5'
        $notes | Should -Match 'vm-state v17 -> v18'
    }
}

Describe 'MANA-LINUX-KERNEL-1: where the choice is offered' {
    It 'a Linux machine whose target can give MANA: every NVMe move, and v5 unless the size cannot' -TestCases @(
        @{ Os = 'Linux'; Move = 'nvme-conversion'; Mana = $true; Want = $true }
        @{ Os = 'Linux'; Move = 'nvme-conversion'; Mana = $null; Want = $true }
        @{ Os = 'Linux'; Move = 'scsi-resize'; Mana = $true; Want = $true }
        @{ Os = 'Linux'; Move = 'scsi-resize'; Mana = $null; Want = $true }
        @{ Os = 'Linux'; Move = 'scsi-resize'; Mana = $false; Want = $false }
        @{ Os = 'Linux'; Move = 'scsi-reversion'; Mana = $true; Want = $false }
        @{ Os = 'Windows'; Move = 'nvme-conversion'; Mana = $true; Want = $false }
        @{ Os = ''; Move = 'nvme-conversion'; Mana = $true; Want = $false }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ Os = $Os; Move = $Move; Mana = $Mana; Want = $Want } {
            param($Os, $Move, $Mana, $Want)
            Test-VmfKernelUpdateOffered -Os $Os -Move $Move -MayUseMana $Mana | Should -Be $Want
        }
    }

    It 'for a plan entry, from its OS, its move and its target size' {
        InModuleScope VmMigrationFactory {
            $e = { param($os, $size, $ctl) [pscustomobject]@{ assessment = [pscustomobject]@{ os = $os }; target = [pscustomobject]@{ size = $size; controller = $ctl } } }
            Test-VmfKernelUpdateOfferedForEntry -PlanEntry (& $e 'Linux' 'Standard_D2ds_v6' 'NVMe') | Should -BeTrue
            Test-VmfKernelUpdateOfferedForEntry -PlanEntry (& $e 'Linux' 'Standard_D2ds_v5' 'SCSI') | Should -BeTrue -Because 'Intel v5 can give MANA'
            Test-VmfKernelUpdateOfferedForEntry -PlanEntry (& $e 'Linux' 'Standard_D2ads_v5' 'SCSI') | Should -BeFalse -Because 'AMD v5 never gives MANA'
            Test-VmfKernelUpdateOfferedForEntry -PlanEntry (& $e 'Windows' 'Standard_D2ds_v6' 'NVMe') | Should -BeFalse
            Test-VmfKernelUpdateOfferedForEntry -PlanEntry (& $e 'Linux' $null 'NVMe') | Should -BeFalse -Because 'a machine with no target does not move'
        }
    }
}

Describe 'MANA-LINUX-KERNEL-1: the choice is saved with the targets, and carried into the plan' {
    BeforeAll {
        function Global:KuSku([string]$Name, [string]$TempMb = '0', [string]$Gens = 'V2') {
            [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
                Capabilities = @(
                    [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                    [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                    [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                    [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                    [pscustomobject]@{ Name = 'MemoryGB'; Value = '8' }
                    [pscustomobject]@{ Name = 'PremiumIO'; Value = 'True' }
                    [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
        }
        function Global:KuVm([string]$Name, [string]$Size, [string]$Os, [string]$OsVersion, [string]$Arch) {
            [ordered]@{
                vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
                name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @(); classification = 'ReadyAfterPrep'; gen = 'V2'
                os = $Os; osVersion = $OsVersion; sourceSize = $Size; sourceDiskArch = $Arch
                sourceTempDisks = $(if ($Arch -eq 'scsi-temp') { 1 } else { 0 }); diskController = 'SCSI'
                dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true; platformManaged = $false; iacManaged = $false
                hibernationEnabled = $false; availabilitySetId = ''; identityType = 'None'; tags = @{ app = $Name }
                blockers = @(); prepNeeded = @()
            }
        }
        function Global:KuId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
        function Global:KuVersion($rp, [string]$Name) {
            InModuleScope VmMigrationFactory -Parameters @{ p = $rp; n = $Name } {
                if (-not (Test-VmfStoreItem -RunPath $p -RelPath $n)) { return '' }
                Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $p -RelPath $n))
            }
        }
        # A reviewed assessment with its options: a Linux machine (v5 Intel and
        # v6), a Windows machine, and a Linux machine on AMD v4 (v5 AMD, which
        # never gives MANA, and v6, which does).
        function Global:KuReviewed {
            $rp = Join-Path $script:work "ku-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $rp -Leaf); generatedUtc = '2026-09-26T00:00:00Z'
                scope = @{ subscriptions = @() }; summary = @{}
                vms = @((KuVm 'lin-01' 'Standard_D2ds_v4' 'Linux' '22_04-lts-gen2' 'scsi-temp'),
                        (KuVm 'win-01' 'Standard_D2ds_v4' 'Windows' '2022-datacenter-g2' 'scsi-temp'),
                        (KuVm 'amd-01' 'Standard_D2as_v4' 'Linux' '22_04-lts-gen2' 'diskless')) }
            InModuleScope VmMigrationFactory -Parameters @{ p = $rp; d = $doc } {
                Initialize-VmfRun -RunPath $p -RunId (Split-Path $p -Leaf) -Kind 'assessment' | Out-Null
                Write-VmfStoreJson -RunPath $p -RelPath 'assessment.json' -Document $d -Depth 24
            }
            Approve-VmfAssessment -RunPath $rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
            New-VmfTargetAdvice -AssessmentPath (Join-Path $rp 'assessment.json') | Out-Null
            $rp
        }
        function Global:KuSave($rp, $Choices, [string]$KernelDefault = 'stop') {
            Set-VmfTestTargetChoice -RunPath $rp -Choices $Choices -Default 'current' -KernelDefault $KernelDefault `
                -ExpectedAdviceVersion (KuVersion $rp 'target-advice.json') -ExpectedChoicesVersion (KuVersion $rp 'target-choices.json') `
                -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }
        }
        function Global:KuPlan($rp) {
            $out = Join-Path $script:work "ku-plan-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            New-VmfPlan -AssessmentPath (Join-Path $rp 'assessment.json') -OutPath $out -RequireTargets -WaveStrategy singleWave | Out-Null
            $text = Get-Content (Join-Path $out 'plan.json') -Raw
            $plan = $text | ConvertFrom-Json -Depth 30
            $plan | Add-Member -NotePropertyName rawText -NotePropertyValue $text -Force
            $plan | Add-Member -NotePropertyName runPath -NotePropertyValue $out -Force
            $plan
        }
        function Global:KuEntry($plan, [string]$Name) { @($plan.entries) | Where-Object { $_.vmId -eq (KuId $Name) } }
    }
    AfterAll { Remove-Item 'function:\KuSku', 'function:\KuVm', 'function:\KuId', 'function:\KuVersion', 'function:\KuReviewed', 'function:\KuSave', 'function:\KuPlan', 'function:\KuEntry' -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:catalog = @((KuSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (KuSku 'Standard_D2s_v5' '0' 'V1,V2'), (KuSku 'Standard_D2ds_v6'), (KuSku 'Standard_D2s_v6'),
                            (KuSku 'Standard_D2ads_v5' '76800' 'V1,V2'), (KuSku 'Standard_D2as_v5' '0' 'V1,V2'), (KuSku 'Standard_D2ads_v6'), (KuSku 'Standard_D2as_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:rp = KuReviewed
    }

    It 'the options say what the choice needs: Linux on v5 Intel and v6, Windows, and AMD v5 that cannot give MANA' {
        $a = Get-Content (Join-Path $script:rp 'target-advice.json') -Raw | ConvertFrom-Json -Depth 30
        $amd = @($a.machines) | Where-Object name -eq 'amd-01'
        $v5 = @($amd.options) | Where-Object option -eq 'v5'
        $v5.supported | Should -BeTrue -Because "the fleet must hold a v5 target that cannot give MANA: $(@($v5.notSupported) -join ',')"
        $v5.acceleratedNetworking.mayUseMana | Should -BeFalse
        (@((@($a.machines) | Where-Object name -eq 'lin-01').options) | Where-Object option -eq 'v6').supported | Should -BeTrue
        (@((@($a.machines) | Where-Object name -eq 'win-01').options) | Where-Object option -eq 'v6').supported | Should -BeTrue
    }

    It 'saves the default and each machine''s own choice, and the document meets its schema' {
        KuSave $script:rp @(@{ vmId = (KuId 'lin-01'); option = 'v6'; kernel = 'update' }, @{ vmId = (KuId 'win-01'); option = 'v6' }) 'stop' | Out-Null
        $text = Get-Content (Join-Path $script:rp 'target-choices.json') -Raw
        $doc = $text | ConvertFrom-Json -Depth 20
        $doc.schemaVersion | Should -Be 9 -Because 'TARGETS-NO-LIST-1 made the targets v9'
        $doc.kernelDefault | Should -Be 'stop'
        (@($doc.choices) | Where-Object vmId -eq (KuId 'lin-01')).kernel | Should -Be 'update'
        (@($doc.choices) | Where-Object vmId -eq (KuId 'win-01')).kernel | Should -BeNullOrEmpty
        $text | Test-Json -SchemaFile (Join-Path $script:schemas 'target-choices.schema.json') | Should -BeTrue
    }

    It 'with no default named, the default is stop' {
        Set-VmfTestTargetChoice -RunPath $script:rp -Choices @(@{ vmId = (KuId 'lin-01'); option = 'v6' }) -Default 'current' `
            -ExpectedAdviceVersion (KuVersion $script:rp 'target-advice.json') -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = $null } | Out-Null
        (Get-Content (Join-Path $script:rp 'target-choices.json') -Raw | ConvertFrom-Json).kernelDefault | Should -Be 'stop'
    }

    It 'refuses Update the kernel for a Windows machine, and for a target that cannot give MANA - and saves nothing' {
        { KuSave $script:rp @(@{ vmId = (KuId 'win-01'); option = 'v6'; kernel = 'update' }) } | Should -Throw '400*win-01*'
        { KuSave $script:rp @(@{ vmId = (KuId 'amd-01'); option = 'v5'; kernel = 'update' }) } | Should -Throw '400*amd-01*'
        { KuSave $script:rp @(@{ vmId = (KuId 'lin-01'); option = 'v6'; kernel = 'sometimes' }) } | Should -Throw '400*sometimes*'
        Test-Path (Join-Path $script:rp 'target-choices.json') | Should -BeFalse
        # The same AMD machine on v6, which can give MANA, may.
        { KuSave $script:rp @(@{ vmId = (KuId 'amd-01'); option = 'v6'; kernel = 'update' }) } | Should -Not -Throw
    }

    It 'through the service, as the page saves: the default and each machine''s own choice arrive' {
        $claims = @(@{ typ = 'preferred_username'; val = 'person@example.com' }, @{ typ = 'roles'; val = 'Vmf.Operator' })
        $principal = ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5))))
        $body = @([pscustomobject]@{ vmId = (KuId 'lin-01'); option = 'v6'; kernel = 'stop' }, [pscustomobject]@{ vmId = (KuId 'amd-01'); option = 'v6' })
        Invoke-VmfTestFacadeSetTargets -Principal $principal -StorePath $script:rp -Default 'current' -Choices $body -KernelDefault 'stop' `
            -AdviceVersion (KuVersion $script:rp 'target-advice.json') -ChoicesVersion '' | Out-Null
        $doc = Get-Content (Join-Path $script:rp 'target-choices.json') -Raw | ConvertFrom-Json -Depth 20
        $doc.kernelDefault | Should -Be 'stop'
        (@($doc.choices) | Where-Object vmId -eq (KuId 'lin-01')).kernel | Should -Be 'stop'
        # KERNEL-DEFAULT-EARLIER-1: the page always sends stop; update is refused too.
        foreach ($other in 'always', 'update') {
            { Invoke-VmfTestFacadeSetTargets -Principal $principal -StorePath $script:rp -Default 'current' -Choices $body -KernelDefault $other `
                -AdviceVersion (KuVersion $script:rp 'target-advice.json') -ChoicesVersion (KuVersion $script:rp 'target-choices.json') } | Should -Throw '400: the kernel default must be stop'
        }
    }
    It 'the plan carries it as the machine''s OWN decision: updateKernel, with who chose it' {
        KuSave $script:rp @(@{ vmId = (KuId 'lin-01'); option = 'v6'; kernel = 'update' }, @{ vmId = (KuId 'win-01'); option = 'v6' },
                            @{ vmId = (KuId 'amd-01'); option = 'v6' }) 'stop' | Out-Null
        $plan = KuPlan $script:rp
        $lin = KuEntry $plan 'lin-01'
        $lin.policy.onDriverBelowFloor | Should -Be 'updateKernel'
        @($lin.decisions).Count | Should -Be 1
        $lin.decisions[0].setting | Should -Be 'onDriverBelowFloor'
        $lin.decisions[0].by | Should -Be 'operator@example.com'
        # Read as the STORED text: ConvertFrom-Json turns a time into a date.
        $plan.rawText | Should -Match '"utc":\s*"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ"' -Because 'whole seconds, as every decision record (PLANVER-2)'
        (KuEntry $plan 'amd-01').policy.onDriverBelowFloor | Should -Be 'stop' -Because 'the default is stop'
        (KuEntry $plan 'amd-01').PSObject.Properties['decisions'] | Should -BeNullOrEmpty
        foreach ($e in @($plan.entries)) {
            ($e | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:schemas 'plan-entry.schema.json') | Should -BeTrue
        }
    }

    It 'KERNEL-DEFAULT-EARLIER-1: only a machine''s own choice updates its kernel; Set-VmfTargetChoice refuses another default' {
        { KuSave $script:rp @(@{ vmId = (KuId 'lin-01'); option = 'v6' }) 'update' } | Should -Throw '*update*'
        Test-Path (Join-Path $script:rp 'target-choices.json') | Should -BeFalse
        KuSave $script:rp @(@{ vmId = (KuId 'lin-01'); option = 'v6' }, @{ vmId = (KuId 'win-01'); option = 'v6' }) 'stop' | Out-Null
        # A file that says update by hand is planned on each machine's own choice only.
        $file = Join-Path $script:rp 'target-choices.json'
        $doc = Get-Content $file -Raw | ConvertFrom-Json -Depth 20
        $doc.kernelDefault = 'update'
        [System.IO.File]::WriteAllText($file, ($doc | ConvertTo-Json -Depth 20))
        $plan = KuPlan $script:rp
        (KuEntry $plan 'lin-01').policy.onDriverBelowFloor | Should -Be 'stop'
        (KuEntry $plan 'lin-01').PSObject.Properties['decisions'] | Should -BeNullOrEmpty
    }
    It 'a target changed in the wave editor to one that cannot give MANA clears it, and says so (review finding 6)' {
        KuSave $script:rp @(@{ vmId = (KuId 'amd-01'); option = 'v6'; kernel = 'update' }) 'stop' | Out-Null
        $plan = KuPlan $script:rp
        (KuEntry $plan 'amd-01').policy.onDriverBelowFloor | Should -Be 'updateKernel'
        $r = Set-VmfMachineTarget -RunPath $plan.runPath -VmId (KuId 'amd-01') -Option 'v5' -ChangedBy 'operator@example.com'
        $r.KernelChoiceCleared | Should -Match 'cannot use MANA'
        $after = Get-Content (Join-Path $plan.runPath 'plan.json') -Raw | ConvertFrom-Json -Depth 30
        $amd = @($after.entries) | Where-Object vmId -eq (KuId 'amd-01')
        $amd.policy.onDriverBelowFloor | Should -Be 'stop'
        $amd.PSObject.Properties['decisions'] | Should -BeNullOrEmpty
    }

    It 'a wave save never writes over it: no wave has a kernel setting (WAVE-KERNEL-LINE-1)' {
        KuSave $script:rp @(@{ vmId = (KuId 'lin-01'); option = 'v6'; kernel = 'update' }, @{ vmId = (KuId 'amd-01'); option = 'v6' }) 'stop' | Out-Null
        $plan = KuPlan $script:rp
        $wave = (KuEntry $plan 'lin-01').wave
        InModuleScope VmMigrationFactory -Parameters @{ entries = @($plan.entries); wave = $wave; ids = @($plan.entries | ForEach-Object vmId) } {
            param($entries, $wave, $ids)
            # The card sends every setting it shows, with a change; none is a
            # kernel setting, so nothing touches the machine's own choice.
            $layout = @{ waves = @(@{ name = $wave; vmIds = $ids; onDDataFound = 'stop'; keepSnapshotDays = 9; changed = @{ keepSnapshotDays = 7 } }) }
            $judged = Get-VmfWaveSettingWrites -Entries $entries -Waves @(ConvertTo-VmfWaveLayout -Layout $layout)
            @($judged.Writes | Where-Object { $_.Field -eq 'onDriverBelowFloor' }) | Should -BeNullOrEmpty
            @($judged.Kept | Where-Object { $_.Field -eq 'onDriverBelowFloor' }) | Should -BeNullOrEmpty
            @($judged.Writes | Where-Object { $_.Field -eq 'keepSnapshotDays' }).Machine | Should -Contain 'lin-01'
            # And a card that still names one is refused, so nothing is written.
            { ConvertTo-VmfWaveLayout -Layout @{ waves = @(@{ name = $wave; vmIds = $ids; onDriverBelowFloor = 'stop' }) } } |
                Should -Throw '*A wave has no kernel choice*'
        }
    }
}

Describe 'MANA-LINUX-KERNEL-1: what the engine reads' {
    It 'accelerated networking reads updateKernel as a stop, never as proceed' {
        InModuleScope VmMigrationFactory {
            $entry = [pscustomobject]@{ assessment = [pscustomobject]@{ os = 'Linux' }
                target = [pscustomobject]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe' }
                path = 'A'; policy = [pscustomobject]@{ onDriverBelowFloor = 'updateKernel' } }
            $nics = @([pscustomobject]@{ id = 'nic0'; primary = $true; acceleratedNetworking = $true })
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $entry -CapturedNics $nics -ManaDriver 'absent'
            $r.Stop | Should -BeTrue
            $r.Reason | Should -Be 'driverBelowFloor'
        }
    }

    It 'an update goes ahead only for a release Microsoft lists' {
        InModuleScope VmMigrationFactory {
            (Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'ubuntu'; distroVersion = '22.04'; kernelVersion = '5.15.0-1031-azure' })).Update | Should -BeTrue
            # AN-MANA-DRIVER-RULE-1: Red Hat 9.4 goes ahead now - a normal update
            # reaches the 9.6 row (minorReachedByUpdate). SUSE 15 SP4 does not.
            (Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'rhel'; distroVersion = '9.4'; kernelVersion = '5.14.0-427.13.1.el9_4.x86_64' })).Update | Should -BeTrue
            (Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'sles'; distroVersion = '15.4'; kernelVersion = '5.14.21-150400.24.1' })).Update | Should -BeFalse -Because 'SUSE 15 SP4 is earlier than the 15.5 row, and a service pack is not a normal update'
            $u20 = Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'ubuntu'; distroVersion = '20.04'; kernelVersion = '5.4.0-1109-azure' })
            $u20.Update | Should -BeFalse
            $u20.Detail | Should -Match 'does not list ubuntu 20.04'
            (Resolve-VmfKernelUpdate -Os 'Windows' -Facts ([pscustomobject]@{ distroId = 'ubuntu'; distroVersion = '22.04'; kernelVersion = '5.15.0-1031-azure' })).Update | Should -BeFalse
            (Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = ''; distroVersion = ''; kernelVersion = '' })).Update | Should -BeFalse
        }
    }

    It 'KERNEL-CHOICE-STOP-ADVICE-1: an unlisted release is said as one, and names the release to upgrade to' {
        InModuleScope VmMigrationFactory {
            $u20 = Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'ubuntu'; distroVersion = '20.04'; kernelVersion = '5.4.0-1109-azure' })
            $u20.Unlisted | Should -BeTrue
            $u20.Detail | Should -Match 'Upgrade the operating system to ubuntu 22\.04 or a later release\.'
            $s154 = Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'sles'; distroVersion = '15.4'; kernelVersion = '5.14.21-150400.24.1' })
            $s154.Unlisted | Should -BeTrue
            $s154.Detail | Should -Match 'to sles 15\.5 or a later release'
            # A distribution the table does not list at all names no release.
            $c7 = Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'centos'; distroVersion = '7'; kernelVersion = '3.10.0-1160.el7.x86_64' })
            $c7.Unlisted | Should -BeTrue
            $c7.Detail | Should -Not -Match 'Upgrade the operating system to'
            # Oracle Linux 9 on UEK R7: the release IS listed (Red Hat compatible
            # kernel, and UEK R8 on any release); only the UEK series is not.
            # So it is not said as an unlisted release, and no upgrade is named.
            $uek7 = Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'ol'; distroVersion = '9.4'; kernelVersion = '5.15.0-300.163.18.el9uek.x86_64' })
            $uek7.Update | Should -BeFalse
            [bool]$uek7.Unlisted | Should -BeFalse
            $uek7.Detail | Should -Not -Match 'Upgrade the operating system'
            $uek7.UekNotListed | Should -BeTrue
            # What is not an unlisted release is not said as one.
            [bool](Resolve-VmfKernelUpdate -Os 'Windows' -Facts ([pscustomobject]@{ distroId = 'ubuntu'; distroVersion = '22.04'; kernelVersion = '5.15.0-1031-azure' })).Unlisted | Should -BeFalse
            [bool](Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = ''; distroVersion = ''; kernelVersion = '' })).Unlisted | Should -BeFalse
            [bool](Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'ubuntu'; distroVersion = '22.04'; kernelVersion = '5.15.0-1031-azure' })).Unlisted | Should -BeFalse
        }
    }

    # ORACLE-UEK7-KERNEL-STOP-1. Microsoft's MANA table lists UEK R8 (6.12) and
    # says UEK R7 is not listed. Oracle: UEK R8 is for Oracle Linux 9 and 10, in
    # ol9_UEKR8 and ol10_UEKR8, and an update does not switch a machine to it.
    # kernel-update.sh never changes repositories, so the product does not run
    # the update: the stop names the UEK kernel and the repository.
    It 'ORACLE-UEK7-KERNEL-STOP-1: a UEK kernel with no row is said as the kernel, with the UEK R8 repository' -TestCases @(
        @{ Version = '9.4'; Kernel = '5.15.0-300.163.18.el9uek.x86_64'; Says = @('the UEK kernel 5\.15\.0-300\.163\.18\.el9uek\.x86_64', 'Microsoft lists UEK R8', 'for Oracle Linux 9 in the ol9_UEKR8 repository', 'Microsoft also lists Oracle Linux 9 on the Red Hat Compatible Kernel'); Not = 'Upgrade the operating system|ol10_UEKR8' }
        @{ Version = '10.0'; Kernel = '5.15.0-300.163.18.el10uek.x86_64'; Says = @('for Oracle Linux 10 in the ol10_UEKR8 repository', 'Microsoft also lists Oracle Linux 10 on the Red Hat Compatible Kernel'); Not = 'Upgrade the operating system|ol9_UEKR8' }
        # Oracle gives UEK R8 for no Oracle Linux 8, and the table lists no
        # Oracle Linux 8 on the Red Hat Compatible Kernel either.
        @{ Version = '8.10'; Kernel = '5.15.0-209.161.7.2.el8uek.x86_64'; Says = @('the UEK kernel 5\.15\.0-209', 'Oracle gives UEK R8 only for Oracle Linux 9 and 10\.', 'Upgrade the operating system to Oracle Linux 9 or a later release\.'); Not = '_UEKR8|Red Hat Compatible Kernel' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ Version = $Version; Kernel = $Kernel; Says = $Says; Not = $Not } {
            param($Version, $Kernel, $Says, $Not)
            $r = Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'ol'; distroVersion = $Version; kernelVersion = $Kernel })
            $r.Update | Should -BeFalse
            $r.UekNotListed | Should -BeTrue
            [bool]$r.Unlisted | Should -BeFalse -Because 'the release is listed; only the UEK kernel is not'
            foreach ($s in $Says) { $r.Detail | Should -Match $s }
            $r.Detail | Should -Not -Match $Not
            $r.Detail | Should -Not -Match '(?i)does not list ol '
        }
    }

    # ORACLE-UEK-UPDATE-1 (2026-11-14: the update covers Oracle UEK too). Lab
    # 2026-11-14: Oracle Linux 9.7 on UEK R7 with ol9_UEKR8 enabled stopped
    # with uekKernelNotListedForMana, whose words said the machine needed the
    # repository it had. mana-check.sh now reports the enabled UEK repositories
    # (uekRepositories, vmf.guest/5): with the UEK R8 repository of the
    # release enabled, the update runs; else the stop says that repository is
    # not enabled.
    It 'ORACLE-UEK-UPDATE-1: Oracle Linux <Version> on <Kernel> with <Repos>: update <Update>' -TestCases @(
        @{ Version = '9.7'; Kernel = '5.15.0-326.224.5.1.el9uek.x86_64'; Repos = 'ol9_UEKR7 ol9_UEKR8'; Update = $true }
        @{ Version = '9.7'; Kernel = '5.15.0-326.224.5.1.el9uek.x86_64'; Repos = 'ol9_UEKR8'; Update = $true }
        @{ Version = '10.0'; Kernel = '5.15.0-300.163.18.el10uek.x86_64'; Repos = 'ol10_UEKR8'; Update = $true }
        # UEK R6 (5.4) is below UEK R8 too.
        @{ Version = '9.4'; Kernel = '5.4.17-2136.330.7.el9uek.x86_64'; Repos = 'ol9_UEKR8'; Update = $true }
        # Off, or another release's repository, or a name that only begins the same.
        @{ Version = '9.7'; Kernel = '5.15.0-326.224.5.1.el9uek.x86_64'; Repos = 'ol9_UEKR7'; Update = $false }
        @{ Version = '9.7'; Kernel = '5.15.0-326.224.5.1.el9uek.x86_64'; Repos = 'none'; Update = $false }
        @{ Version = '9.7'; Kernel = '5.15.0-326.224.5.1.el9uek.x86_64'; Repos = 'ol10_UEKR8'; Update = $false }
        @{ Version = '9.7'; Kernel = '5.15.0-326.224.5.1.el9uek.x86_64'; Repos = 'ol9_UEKR8_test'; Update = $false }
        # Oracle gives no UEK R8 for Oracle Linux 8: its stop stays.
        @{ Version = '8.10'; Kernel = '5.15.0-209.161.7.2.el8uek.x86_64'; Repos = 'ol9_UEKR8 ol8_UEKR7'; Update = $false }
        # A UEK kernel of a later series than UEK R8 is never sent to it.
        @{ Version = '9.7'; Kernel = '6.14.0-1.el9uek.x86_64'; Repos = 'ol9_UEKR8'; Update = $false }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ Version = $Version; Kernel = $Kernel; Repos = $Repos; Update = $Update } {
            param($Version, $Kernel, $Repos, $Update)
            $r = Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'ol'; distroVersion = $Version; kernelVersion = $Kernel; uekRepositories = $Repos })
            $r.Update | Should -Be $Update
            if ($Update) {
                [bool]$r.UekNotListed | Should -BeFalse
                [bool]$r.Unlisted | Should -BeFalse
            }
            else { $r.UekNotListed | Should -BeTrue }
        }
    }

    It 'ORACLE-UEK-UPDATE-1: the stop says the UEK R8 repository is not enabled, or could not be read - never that the machine needs one it has' {
        InModuleScope VmMigrationFactory {
            $off = Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'ol'; distroVersion = '9.7'; kernelVersion = '5.15.0-326.224.5.1.el9uek.x86_64'; uekRepositories = 'ol9_UEKR7' })
            $off.Detail | Should -Match 'The ol9_UEKR8 repository is not enabled on the machine, and the product does not change repositories\.'
            $off.Detail | Should -Match 'Enable the ol9_UEKR8 repository with the steps from Oracle\. Then the product can install UEK R8 when you retry the machine\.'
            $off.Detail | Should -Not -Match 'could not read'
            # No report: no repository folder on the machine.
            foreach ($facts in @(
                    [pscustomobject]@{ distroId = 'ol'; distroVersion = '9.7'; kernelVersion = '5.15.0-326.224.5.1.el9uek.x86_64' }
                    [pscustomobject]@{ distroId = 'ol'; distroVersion = '9.7'; kernelVersion = '5.15.0-326.224.5.1.el9uek.x86_64'; uekRepositories = 'unknown' })) {
                $unread = Resolve-VmfKernelUpdate -Os 'Linux' -Facts $facts
                $unread.Update | Should -BeFalse
                $unread.Detail | Should -Match 'The product could not read whether the ol9_UEKR8 repository is enabled on the machine\.'
                $unread.Detail | Should -Not -Match 'is not enabled'
            }
            # Oracle Linux 8 keeps its own words: no repository to enable.
            $ol8 = Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'ol'; distroVersion = '8.10'; kernelVersion = '5.15.0-209.161.7.2.el8uek.x86_64'; uekRepositories = 'ol8_UEKR7' })
            $ol8.Detail | Should -Match 'Upgrade the operating system to Oracle Linux 9'
            $ol8.Detail | Should -Not -Match 'not enabled|could not read|Enable the'
        }
    }

    It 'ORACLE-UEK7-KERNEL-STOP-1: the Red Hat Compatible Kernel is named only where the table has its row' {
        $file = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'driver-floors.json'
        $floors = Get-Content $file -Raw | ConvertFrom-Json
        $floors.mana.linux.distros = @(@($floors.mana.linux.distros) | Where-Object { -not ($_.id -eq 'ol' -and $_.versionId -eq '10' -and -not $_.PSObject.Properties['kernelFlavor']) })
        InModuleScope VmMigrationFactory -Parameters @{ floors = $floors } {
            param($floors)
            $r = Resolve-VmfKernelUpdate -Os 'Linux' -Floors $floors -Facts ([pscustomobject]@{ distroId = 'ol'; distroVersion = '10.0'; kernelVersion = '5.15.0-300.163.18.el10uek.x86_64' })
            $r.UekNotListed | Should -BeTrue
            $r.Detail | Should -Match 'in the ol10_UEKR8 repository\.'
            $r.Detail | Should -Not -Match 'Red Hat Compatible Kernel'
        }
    }

    It 'ORACLE-UEK7-KERNEL-STOP-1: UEK R8 on its row is updated as before, and a Red Hat Compatible Kernel is never said as UEK' {
        InModuleScope VmMigrationFactory {
            $r8 = Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'ol'; distroVersion = '9.4'; kernelVersion = '6.12.0-0.20.20.el9uek.x86_64' })
            $r8.Update | Should -BeTrue
            [bool]$r8.UekNotListed | Should -BeFalse
            $rhck = Resolve-VmfKernelUpdate -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'ol'; distroVersion = '8.10'; kernelVersion = '4.18.0-553.el8_10.x86_64' })
            [bool]$rhck.UekNotListed | Should -BeFalse
            $rhck.Unlisted | Should -BeTrue
        }
    }

    It 'ORACLE-UEK7-KERNEL-STOP-1: the UEK R8 facts are data, with Oracle as the source' {
        $floors = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'driver-floors.json') -Raw | ConvertFrom-Json
        $u = $floors.mana.linux.uekR8
        $u | Should -Not -BeNullOrEmpty
        $u.kernelSeries | Should -Be '6.12'
        $u.kernelSeries | Should -Be (@($floors.mana.linux.distros) | Where-Object { $_.kernelFlavor -eq 'uek' }).kernelSeries -Because 'the UEK row of Microsoft''s table and Oracle''s UEK R8 are one kernel series'
        $u.package | Should -Be 'kernel-uek'
        @($u.repositories | ForEach-Object { "$($_.versionId)=$($_.repository)" }) | Should -Be @('9=ol9_UEKR8', '10=ol10_UEKR8')
        foreach ($url in $u.sources) {
            $url | Should -Match '^https://docs\.oracle\.com/'
            @($floors.sources.url) | Should -Contain $url
        }
        @($u.sources).Count | Should -BeGreaterOrEqual 2
    }

    It 'what the update script answered: FIXED restarts; NO_CHANGE, BLOCKED and nothing do not' {
        InModuleScope VmMigrationFactory {
            $out = { param($r, $e) $o = [pscustomobject]@{ result = $r; checks = @(
                        [pscustomobject]@{ name = 'kernel before'; status = 'INFO'; detail = '5.15.0-1031-azure' }
                        [pscustomobject]@{ name = 'package manager'; status = 'INFO'; detail = 'apt-get' }
                        [pscustomobject]@{ name = 'kernel package'; status = 'INFO'; detail = 'linux-azure' }
                        [pscustomobject]@{ name = 'kernel installed'; status = 'INFO'; detail = '5.15.0-1102-azure' }) }
                if ($e) { $o | Add-Member -NotePropertyName error -NotePropertyValue $e }; $o }
            $fixed = Get-VmfKernelUpdateOutcome -GuestOutput (& $out 'FIXED')
            $fixed.Restart | Should -BeTrue
            $fixed.KernelInstalled | Should -Be '5.15.0-1102-azure'
            $fixed.Package | Should -Be 'linux-azure'
            $fixed.PackageManager | Should -Be 'apt-get'
            (Get-VmfKernelUpdateOutcome -GuestOutput (& $out 'NO_CHANGE')).Restart | Should -BeFalse
            $blocked = Get-VmfKernelUpdateOutcome -GuestOutput (& $out 'BLOCKED' 'apt-get could not install linux-azure (exit code 100)')
            $blocked.Restart | Should -BeFalse
            $blocked.Detail | Should -Match 'exit code 100'
            (Get-VmfKernelUpdateOutcome -GuestOutput (& $out 'READY')).Restart | Should -BeFalse -Because 'an answer the engine does not know is never an update'
            (Get-VmfKernelUpdateOutcome -GuestOutput $null).Restart | Should -BeFalse
        }
    }

    It 'after the restart: present and not below the floor passes; anything else, unknown included, does not' {
        InModuleScope VmMigrationFactory {
            (Get-VmfKernelUpdateRecheck -Presence 'present' -Verdict @{ Status = 'PASS' } -KernelBefore 'a' -KernelInstalled 'b' -KernelAfter 'b').Ok | Should -BeTrue
            (Get-VmfKernelUpdateRecheck -Presence 'present' -Verdict @{ Status = 'UNKNOWN' } -KernelBefore 'a' -KernelInstalled 'b' -KernelAfter 'b').Ok | Should -BeTrue
            (Get-VmfKernelUpdateRecheck -Presence 'present' -Verdict @{ Status = 'FAIL'; Detail = 'below' } -KernelBefore 'a' -KernelInstalled 'b' -KernelAfter 'b').Ok | Should -BeFalse
            (Get-VmfKernelUpdateRecheck -Presence 'unknown' -Verdict @{ Status = 'PASS' } -KernelBefore 'a' -KernelInstalled 'b' -KernelAfter 'b').Ok | Should -BeFalse
            $old = Get-VmfKernelUpdateRecheck -Presence 'absent' -Verdict @{ Status = 'FAIL' } -KernelBefore 'a' -KernelInstalled 'b' -KernelAfter 'a'
            $old.Ok | Should -BeFalse
            $old.Detail | Should -Match 'not on the installed kernel b'
        }
    }

    It 'SAFETY_PRISTINE comes before GUEST_PREP, so the update always has a way back' {
        InModuleScope VmMigrationFactory {
            $order = @((Get-VmfEngineStates).Working)
            [array]::IndexOf($order, 'SAFETY_PRISTINE') | Should -BeLessThan ([array]::IndexOf($order, 'GUEST_PREP'))
        }
        $sm = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $precheck = [regex]::Match($sm, '(?s)function Invoke-VmfStepPrecheck.*?\n\}').Value
        $precheck | Should -Match "return @\{ Next = 'SAFETY_PRISTINE'"
        $pristine = [regex]::Match($sm, '(?s)function Invoke-VmfStepSafetyPristine.*?\n\}').Value
        @([regex]::Matches($pristine, "Next = '([A-Z_]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique) | Should -Be @('GUEST_PREP')
    }
}

Describe 'MANA-LINUX-KERNEL-1: RUN the preparation step' {
    BeforeAll {
        function Global:KpPlan([string]$Floor = 'updateKernel', [string]$Os = 'Linux', [string]$Size = 'Standard_D2ds_v6', [string]$Controller = 'NVMe') {
            [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/kpvm'
                wave = 'w1'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                    sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'; platformManaged = $false }
                target = [pscustomobject]@{ size = $Size; diskArch = 'nvme-temp'; controller = $Controller }
                path = 'A'
                policy = [pscustomobject]@{ onDriverBelowFloor = $Floor; onDDataFound = 'stop' }
            }
        }
        # mana-check.sh as a machine reports it: a kernel, whether modinfo
        # finds mana, and the release.
        # ORACLE-UEK-UPDATE-1: on Oracle Linux it also reports the enabled UEK
        # repositories (vmf.guest/5).
        function Global:KpMana([string]$Kernel, [bool]$Module, [string]$Distro = 'ubuntu', [string]$Version = '22.04', [string]$UekRepos = '', [hashtable]$Extra = @{}) {
            $o = [pscustomobject]@{ schema = 'vmf.guest/2'; script = 'mana-check.sh'; version = '1.1.0'; os = "$Distro $Version"
                result = $(if ($Module) { 'READY' } else { 'NEEDS_PREP' }); warnings = @()
                checks = @([pscustomobject]@{ name = 'kernel'; status = 'INFO'; detail = $Kernel }
                    [pscustomobject]@{ name = 'mana module available'; status = $(if ($Module) { 'PASS' } else { 'WARN' }); detail = 'modinfo mana' })
                facts = [pscustomobject]@{ os = 'Linux'; kernelVersion = $Kernel; distroId = $Distro; distroVersion = $Version; fabric = 'mlx5' } }
            if ($UekRepos) {
                $o.schema = 'vmf.guest/5'; $o.version = '1.2.0'
                $o.facts | Add-Member -NotePropertyName uekRepositories -NotePropertyValue $UekRepos
            }
            # KERNEL-OFFER-EDGES-1 / KERNEL-FLOOR-UPLOAD-1: releaseverLock and
            # kernelPackageVersion (vmf.guest/6).
            foreach ($k in $Extra.Keys) {
                $o.schema = 'vmf.guest/6'; $o.version = '1.3.0'
                $o.facts | Add-Member -NotePropertyName $k -NotePropertyValue $Extra[$k] -Force
            }
            $o
        }
        function Global:KpUpdate([string]$Result, [string]$Err = '', [string]$Ran = '') {
            $o = [pscustomobject]@{ schema = 'vmf.guest/2'; script = 'kernel-update.sh'; version = '1.0.0'; os = 'ubuntu 22.04'; result = $Result; warnings = @()
                checks = @([pscustomobject]@{ name = 'kernel before'; status = 'INFO'; detail = '5.15.0-1031-azure' }
                    [pscustomobject]@{ name = 'package manager ran'; status = 'INFO'; detail = $(if ($Ran) { $Ran } else { 'yes' }) }
                    [pscustomobject]@{ name = 'package manager'; status = 'INFO'; detail = 'apt-get' }
                    [pscustomobject]@{ name = 'kernel package'; status = 'INFO'; detail = 'linux-azure' }
                    [pscustomobject]@{ name = 'kernel installed'; status = 'INFO'; detail = '5.15.0-1102-azure' })
                facts = [pscustomobject]@{ os = 'Linux'; kernelVersion = '5.15.0-1031-azure'; distroId = 'ubuntu'; distroVersion = '22.04' } }
            if ($Err) { $o | Add-Member -NotePropertyName error -NotePropertyValue $Err }
            $o
        }
        # A machine with its first safety copy taken, as SAFETY_PRISTINE leaves it.
        function Global:KpMachine($rp, $Plan, [bool]$AnOn = $true, [switch]$NoCopy) {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; plan = $Plan; an = $AnOn; noCopy = [bool]$NoCopy } {
                param($rp, $plan, $an, $noCopy)
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'kp-test'
                New-VmfStateDoc -RunPath $rp -RunId 'kp-test' -VmId $ctx.VmId | Out-Null
                Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ size = 'Standard_D2ds_v4'; dataDisks = @()
                        nics = @([pscustomobject]@{ id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic0'; primary = $true; acceleratedNetworking = $an }) } }
                if (-not $noCopy) {
                    $doc = Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId
                    $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ pristineSnapshotId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/kpvm-pristine'; pristineSnapshotLocked = $true; snapshotId = $null; cloneVmId = $null }) -Force
                    $null = Complete-VmfTestCapture $doc
                    Write-VmfStateDoc -RunPath $rp -Document $doc
                }
                $ctx
            }
        }
    }
    AfterAll { Remove-Item 'function:\KpPlan', 'function:\KpMana', 'function:\KpUpdate', 'function:\KpMachine' -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:rp = Join-Path $script:work ("kp-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'kp-test' | Out-Null }
        $global:kpScripts = [System.Collections.Generic.List[string]]::new()
        $global:kpCalls = [System.Collections.Generic.List[string]]::new()
        # Before the update: Ubuntu 22.04 on a kernel below Microsoft's floor
        # (5.15.0-1096.105). After it: the kernel the update installed.
        $global:kpBefore = Global:KpMana '5.15.0-1031-azure' $true
        $global:kpAfter = Global:KpMana '5.15.0-1102-azure' $true
        $global:kpUpdate = Global:KpUpdate 'FIXED'
        $global:kpRestarted = $false
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:kpCalls.Add('start'); if ($global:kpStopped) { $global:kpRestarted = $true }; if ($global:kpStartFails -and $global:kpStopped) { throw 'AllocationFailed: <placeholder>' } }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:kpCalls.Add('stop'); $global:kpStopped = $true }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { $global:kpCalls.Add('agent'); if ($global:kpAgentFails) { throw "VM 'kpvm' agent did not report Ready within 600s - possible boot failure." } }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            $global:kpScripts.Add($ScriptName)
            switch ($ScriptName) {
                'mana-check.sh' { if ($global:kpRestarted) { return $global:kpAfter } else { return $global:kpBefore } }
                'kernel-update.sh' { return $global:kpUpdate }
                default { return [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1.0.0'; os = 'ubuntu'; result = 'READY'; warnings = @(); checks = @() } }
            }
        }
    }
    AfterEach {
        Remove-Variable kpScripts, kpCalls, kpBefore, kpAfter, kpUpdate, kpRestarted, kpStopped, kpStartFails, kpAgentFails -Scope Global -ErrorAction SilentlyContinue
    }

    It 'a kernel with the driver: nothing is updated' {
        $global:kpBefore = Global:KpMana '5.15.0-1102-azure' $true
        $ctx = KpMachine $script:rp (KpPlan)
        InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED' }
        @($global:kpScripts) | Should -Not -Contain 'kernel-update.sh'
        @($global:kpCalls) | Should -Not -Contain 'stop'
    }

    It 'missing, and the choice is Stop: it stops before anything changes, as before' {
        $ctx = KpMachine $script:rp (KpPlan -Floor 'stop')
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'driverBelowFloor'
        $r.MachineState | Should -Be 'untouched'
        @($global:kpScripts) | Should -Not -Contain 'kernel-update.sh'
    }

    # ORACLE-UEK-UPDATE-1 (lab 2026-11-14): with Update the kernel
    # chosen, the driver reading said "FAIL: kernel ... is below the published
    # minimum", then the update ran. It now says that the update comes next;
    # FAIL stays where the machine stops.
    It 'ORACLE-UEK-UPDATE-1: the driver line says the update comes next when it does, and FAIL where the machine stops (<Case>)' -TestCases @(
        @{ Case = 'Update chosen, release listed'; Floor = 'updateKernel'; Kernel = '5.15.0-1031-azure'; Version = '22.04'; Next = $true }
        @{ Case = 'Stop chosen'; Floor = 'stop'; Kernel = '5.15.0-1031-azure'; Version = '22.04'; Next = $false }
    ) {
        $global:kpLines = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine { if ($Step -eq 'driverCheck') { $global:kpLines.Add([string]$Detail) } }
        $global:kpBefore = Global:KpMana $Kernel $true 'ubuntu' $Version
        $ctx = KpMachine $script:rp (KpPlan -Floor $Floor)
        InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx } | Out-Null
        $first = @($global:kpLines)[0]
        if ($Next) {
            $first | Should -BeExactly 'The kernel 5.15.0-1031-azure is below the minimum version 5.15.0-1096.105 that Microsoft lists for ubuntu 22.04. The product updates the kernel now, as chosen for this machine.'
        }
        else {
            $first | Should -Match '^FAIL: kernel 5\.15\.0-1031-azure is below the published minimum'
        }
        Remove-Variable kpLines -Scope Global -ErrorAction SilentlyContinue
    }

    It 'ORACLE-UEK-UPDATE-1: Get-VmfDriverCheckLine keeps FAIL where no update goes ahead, and every other status as it was' {
        InModuleScope VmMigrationFactory {
            $fail = @{ Status = 'FAIL'; MinKernel = '5.15.0-1096.105'; Detail = 'kernel 5.15.0-1031-azure is below the published minimum 5.15.0-1096.105 for ubuntu 22.04 - x' }
            $ok = [pscustomobject]@{ distroId = 'ubuntu'; distroVersion = '22.04'; kernelVersion = '5.15.0-1031-azure' }
            Get-VmfDriverCheckLine -Verdict $fail -UpdateKernel $true -Os 'Linux' -Facts $ok | Should -Match '^The kernel 5\.15\.0-1031-azure is below the minimum version 5\.15\.0-1096\.105 that Microsoft lists for ubuntu 22\.04\. The product updates the kernel now, as chosen for this machine\.$'
            Get-VmfDriverCheckLine -Verdict $fail -UpdateKernel $false -Os 'Linux' -Facts $ok | Should -BeExactly "FAIL: $($fail.Detail)"
            # A UEK R7 kernel with the UEK R8 repository off: the machine stops.
            $uek = [pscustomobject]@{ distroId = 'ol'; distroVersion = '9.7'; kernelVersion = '5.15.0-326.224.5.1.el9uek.x86_64'; uekRepositories = 'ol9_UEKR7' }
            Get-VmfDriverCheckLine -Verdict $fail -UpdateKernel $true -Os 'Linux' -Facts $uek | Should -BeExactly "FAIL: $($fail.Detail)"
            $pass = @{ Status = 'PASS'; Detail = 'kernel x meets the published minimum y for ubuntu 22.04' }
            Get-VmfDriverCheckLine -Verdict $pass -UpdateKernel $true -Os 'Linux' -Facts $ok | Should -BeExactly "PASS: $($pass.Detail)"
            (Get-VmfDriverJudgement -Facts ([pscustomobject]@{ os = 'Linux'; distroId = 'ubuntu'; distroVersion = '22.04'; kernelVersion = '5.15.0-1031-azure' }) -TargetIsBoost $true).MinKernel | Should -Be '5.15.0-1096.105'
        }
    }

    It 'missing, and the choice is Update: the update, a stop and start, the agent, a second reading - THEN the preparation' {
        $ctx = KpMachine $script:rp (KpPlan)
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx }
        $r.Next | Should -Be 'STOPPED'
        $order = @($global:kpScripts)
        $order.IndexOf('kernel-update.sh') | Should -BeGreaterThan $order.IndexOf('mana-check.sh')
        [array]::LastIndexOf($order, 'mana-check.sh') | Should -BeGreaterThan $order.IndexOf('kernel-update.sh') -Because 'the machine is read again on its new kernel'
        $order.IndexOf('nvme-fix.sh') | Should -BeGreaterThan ([array]::LastIndexOf($order, 'mana-check.sh')) -Because 'the preparation is for the kernel the machine moves with'
        $calls = @($global:kpCalls)
        $calls.IndexOf('stop') | Should -BeLessThan ([array]::LastIndexOf($calls, 'start'))
        [array]::LastIndexOf($calls, 'start') | Should -BeLessThan $calls.IndexOf('agent')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $ctx.VmId } {
            param($rp, $id)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $rec = $doc.captured.kernelUpdate
            $rec.result | Should -Be 'updated'
            $rec.kernelBefore | Should -Be '5.15.0-1031-azure'
            $rec.kernelInstalled | Should -Be '5.15.0-1102-azure'
            $rec.kernelAfter | Should -Be '5.15.0-1102-azure'
            $rec.package | Should -Be 'linux-azure'
            $rec.packageManager | Should -Be 'apt-get'
            $doc.schemaVersion | Should -Be 51   # SAFETY-CMK-1 took v21, ROLLBACK-DISKS-FIRST-1 v22, RECOVER-ALL-DISKS-1 v23, ROLLBACK-CRG-1 v24, SWAP-REFUSED-AFTER-STOP-1 v25, MADE-DISK-RECORD-1 v26, RESTORE-END-JOB-1 v27, FINISH-EMPTY-LUN-PROOF-1 v28, FINISH-KEPT-DISKS-1 v29, RESTORE-EARLIER-DELETE-1 v40
            $doc.captured.driver.facts.kernelVersion | Should -Be '5.15.0-1102-azure' -Because 'the reading on the new kernel replaces the old one'
            $doc.captured.acceleratedNetworking.manaDriver | Should -Be 'present'
        }
    }

    # KERNEL-UPDATE-OL-RHCK-1 (final lab, 2026-11-16, f-olr): the machine
    # restarted on its old RHCK kernel, and the words named a UEK kernel that
    # was never the default. The step hands the default boot kernel the script
    # set to the recheck, and the rollback says it.
    It 'KERNEL-UPDATE-OL-RHCK-1: a restart onto another kernel than the default the script set puts the machine back, and names that default' {
        $old = '5.14.0-570.51.1.0.1.el9_6.x86_64'
        $new = '5.14.0-570.52.1.0.1.el9_6.x86_64'
        $global:kpBefore = Global:KpMana $old $true 'ol' '9.7'
        $global:kpAfter = Global:KpMana $old $true 'ol' '9.7'
        $u = Global:KpUpdate 'FIXED'
        ($u.checks | Where-Object name -EQ 'kernel installed').detail = $new
        $u.checks += [pscustomobject]@{ name = 'default boot kernel'; status = 'FIXED'; detail = $new }
        $global:kpUpdate = $u
        $ctx = KpMachine $script:rp (KpPlan)
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx }
        $r.Next | Should -Be 'FAILED_ROLLED_BACK'
        $r.Reason | Should -Be 'kernelUpdateFailed'
        $r.Detail | Should -Match ([regex]::Escape("The machine started on kernel $old, not on the default boot kernel $new."))
    }

    It 'a release Microsoft does not list: it stops UNTOUCHED, says why, and nothing is updated' {
        $global:kpBefore = Global:KpMana '5.4.0-1109-azure' $false 'ubuntu' '20.04'
        $ctx = KpMachine $script:rp (KpPlan)
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx }
        $r.Next | Should -Be 'NEEDS_DECISION'
        # KERNEL-CHOICE-STOP-ADVICE-1: its own reason - driverBelowFloor says to
        # choose Update the kernel, which this machine already has.
        $r.Reason | Should -Be 'releaseNotListedForMana'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match 'does not list ubuntu 20.04'
        $r.Detail | Should -Match 'Upgrade the operating system to ubuntu 22\.04'
        @($global:kpScripts) | Should -Not -Contain 'kernel-update.sh'
    }

    # ORACLE-UEK7-KERNEL-STOP-1: Oracle Linux 9 on UEK R7, with or without a
    # mana module. Before it, driverBelowFloor said "Microsoft does not list ol
    # 9" and "Choose Update the kernel" - the choice the machine has.
    It 'Oracle Linux 9 on UEK R7 (mana module <Module>): it stops UNTOUCHED with its own reason, names the UEK kernel, and nothing is updated' -TestCases @(
        @{ Module = $true }
        @{ Module = $false }
    ) {
        $global:kpBefore = Global:KpMana '5.15.0-300.163.18.el9uek.x86_64' $Module 'ol' '9.4'
        $ctx = KpMachine $script:rp (KpPlan)
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'uekKernelNotListedForMana'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match 'the UEK kernel 5\.15\.0-300\.163\.18\.el9uek\.x86_64'
        $r.Detail | Should -Match 'ol9_UEKR8'
        $r.Detail | Should -Not -Match 'does not list ol 9'
        @($global:kpScripts) | Should -Not -Contain 'kernel-update.sh'
        @($global:kpCalls) | Should -Not -Contain 'stop'
    }

    # ORACLE-UEK-UPDATE-1: the lab machine of 2026-11-14 - Oracle Linux 9.7 on
    # UEK R7 with ol9_UEKR8 enabled. The update runs, the machine restarts, and
    # it is read again: UEK R8 with a mana module goes on to the preparation.
    It 'ORACLE-UEK-UPDATE-1: Oracle Linux 9.7 on UEK R7 with ol9_UEKR8 enabled: the kernel is updated to UEK R8, then the preparation' {
        $global:kpBefore = Global:KpMana '5.15.0-326.224.5.1.el9uek.x86_64' $true 'ol' '9.7' 'ol9_UEKR7 ol9_UEKR8'
        $global:kpAfter = Global:KpMana '6.12.0-105.51.5.el9uek.x86_64' $true 'ol' '9.7' 'ol9_UEKR7 ol9_UEKR8'
        $global:kpUpdate = Global:KpUpdate 'FIXED'
        ($global:kpUpdate.checks | Where-Object name -eq 'kernel installed').detail = '6.12.0-105.51.5.el9uek.x86_64'
        $ctx = KpMachine $script:rp (KpPlan)
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx }
        $r.Next | Should -Be 'STOPPED'
        @($global:kpScripts) | Should -Contain 'kernel-update.sh'
        @($global:kpCalls) | Should -Contain 'stop'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $ctx.VmId } {
            param($rp, $id)
            $rec = (Read-VmfStateDoc -RunPath $rp -VmId $id).captured.kernelUpdate
            $rec.result | Should -Be 'updated'
            $rec.kernelBefore | Should -Be '5.15.0-326.224.5.1.el9uek.x86_64'
            $rec.kernelAfter | Should -Be '6.12.0-105.51.5.el9uek.x86_64'
        }
    }

    It 'ORACLE-UEK-UPDATE-1: the update gave no UEK R8 (still UEK R7 after the restart): the machine goes back to its pristine copy' {
        $global:kpBefore = Global:KpMana '5.15.0-326.224.5.1.el9uek.x86_64' $false 'ol' '9.7' 'ol9_UEKR8'
        $global:kpAfter = Global:KpMana '5.15.0-326.230.1.el9uek.x86_64' $false 'ol' '9.7' 'ol9_UEKR8'
        $global:kpUpdate = Global:KpUpdate 'FIXED'
        ($global:kpUpdate.checks | Where-Object name -eq 'kernel installed').detail = '5.15.0-326.230.1.el9uek.x86_64'
        $ctx = KpMachine $script:rp (KpPlan)
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx }
        $r.PutBack | Should -BeTrue
        $r.Reason | Should -Be 'kernelUpdateFailed'
        @($global:kpScripts) | Should -Not -Contain 'nvme-fix.sh'
    }

    It 'ORACLE-UEK-UPDATE-1: Oracle Linux 9.7 on UEK R7 with ol9_UEKR8 not enabled: it stops UNTOUCHED and says the repository is not enabled' {
        $global:kpBefore = Global:KpMana '5.15.0-326.224.5.1.el9uek.x86_64' $true 'ol' '9.7' 'ol9_UEKR7'
        $ctx = KpMachine $script:rp (KpPlan)
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'uekKernelNotListedForMana'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match 'The ol9_UEKR8 repository is not enabled on the machine'
        @($global:kpScripts) | Should -Not -Contain 'kernel-update.sh'
        @($global:kpCalls) | Should -Not -Contain 'stop'
    }

    # KERNEL-OFFER-EDGES-1 (2026-11-14): never run an update that
    # cannot succeed. Each of these gave a stop after the script ran, or a real
    # kernel change, a restart and a rollback.
    It 'KERNEL-OFFER-EDGES-1: <Case> with Update the kernel: it stops UNTOUCHED with <Reason>, and the update script never runs' -TestCases @(
        @{ Case = 'Debian 12 on its 6.1 kernel'; Kernel = '6.1.0-41-cloud-amd64'; Distro = 'debian'; Version = '12'; Extra = @{}; Reason = 'kernelUpdateCannotReachMinimum'; Says = 'bookworm-backports' }
        @{ Case = 'SUSE 15 SP5 on kernel-azure'; Kernel = '5.14.21-150500.33.54-azure'; Distro = 'sles'; Version = '15.5'; Extra = @{}; Reason = 'kernelUpdateCannotReachMinimum'; Says = 'kernel-azure' }
        @{ Case = 'RHEL 9.4 held to 9.4'; Kernel = '5.14.0-427.13.1.el9_4.x86_64'; Distro = 'rhel'; Version = '9.4'; Extra = @{ releaseverLock = '9.4' }; Reason = 'kernelUpdateCannotReachMinimum'; Says = 'releasever' }
        @{ Case = 'Ubuntu on the FIPS kernel'; Kernel = '5.15.0-1050-azure-fips'; Distro = 'ubuntu'; Version = '22.04'; Extra = @{}; Reason = 'kernelUpdateNoRule'; Says = 'linux-azure' }
        @{ Case = 'Ubuntu on the generic kernel'; Kernel = '5.15.0-91-generic'; Distro = 'ubuntu'; Version = '22.04'; Extra = @{}; Reason = 'kernelUpdateNoRule'; Says = 'linux-azure' }
    ) {
        $global:kpBefore = Global:KpMana $Kernel $true $Distro $Version '' $Extra
        $ctx = KpMachine $script:rp (KpPlan)
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be $Reason
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match ([regex]::Escape($Says))
        $r.PutBack | Should -Not -BeTrue
        @($global:kpScripts) | Should -Not -Contain 'kernel-update.sh'
        @($global:kpCalls) | Should -Not -Contain 'stop'
    }

    It 'KERNEL-OFFER-EDGES-1: <Case> with Stop and ask: the stop says Update the kernel cannot help (<Reason>), never driverBelowFloor' -TestCases @(
        @{ Case = 'Debian 12 on its 6.1 kernel'; Kernel = '6.1.0-41-cloud-amd64'; Distro = 'debian'; Version = '12'; Reason = 'kernelUpdateCannotReachMinimum' }
        @{ Case = 'Ubuntu on the FIPS kernel'; Kernel = '5.15.0-1050-azure-fips'; Distro = 'ubuntu'; Version = '22.04'; Reason = 'kernelUpdateNoRule' }
    ) {
        $global:kpBefore = Global:KpMana $Kernel $true $Distro $Version
        $ctx = KpMachine $script:rp (KpPlan -Floor 'stop')
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be $Reason
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match 'below the published minimum'
        @($global:kpScripts) | Should -Not -Contain 'kernel-update.sh'
    }

    It 'KERNEL-FLOOR-UPLOAD-1: Ubuntu at the minimum (package 5.15.0-1096.105) with Stop and ask: nothing stops, nothing is updated' {
        $global:kpBefore = Global:KpMana '5.15.0-1096-azure' $true 'ubuntu' '22.04' '' @{ kernelPackageVersion = '5.15.0-1096.105' }
        $ctx = KpMachine $script:rp (KpPlan -Floor 'stop')
        InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED' }
        @($global:kpScripts) | Should -Not -Contain 'kernel-update.sh'
    }

    It 'KERNEL-FLOOR-UPLOAD-1: Ubuntu one upload below the minimum (5.15.0-1096.104) with Update the kernel: the update runs' {
        $global:kpBefore = Global:KpMana '5.15.0-1096-azure' $true 'ubuntu' '22.04' '' @{ kernelPackageVersion = '5.15.0-1096.104' }
        $ctx = KpMachine $script:rp (KpPlan)
        InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx } | Out-Null
        @($global:kpScripts) | Should -Contain 'kernel-update.sh'
    }

    It 'a Windows machine never runs it' {
        $ctx = KpMachine $script:rp (KpPlan -Os 'Windows')
        InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx } | Out-Null
        @($global:kpScripts) | Should -Not -Contain 'kernel-update.sh'
    }

    It 'a target that cannot give MANA (AMD v5): the driver is not asked about, and nothing is updated' {
        $ctx = KpMachine $script:rp (KpPlan -Size 'Standard_D2ads_v5' -Controller 'SCSI')
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx }
        $r.Next | Should -Be 'STOPPED'
        @($global:kpScripts) | Should -Not -Contain 'kernel-update.sh'
    }

    It 'no first safety copy on record: nothing is updated, and it says so' {
        $ctx = KpMachine $script:rp (KpPlan) -NoCopy
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx }
        $r.PutBack | Should -Not -BeTrue
        $r.MachineState | Should -Be 'untouched'
        @($global:kpScripts) | Should -Not -Contain 'kernel-update.sh'
    }

    It '<Case>: nothing changed, so it stops for a person UNTOUCHED - no put-back (review finding 3)' -TestCases @(
        # RHEL-PINNED-KERNEL-ADVICE-1: no newer kernel has its own reason. Its
        # advice must never send the person back to Update the kernel, which
        # is the choice that just found nothing (lab, Red Hat 9.4 on EUS).
        @{ Case = 'no newer kernel'; Setup = { $global:kpUpdate = Global:KpUpdate 'NO_CHANGE' }; Says = 'no kernel newer'; Reason = 'kernelNotInRepositories' }
        @{ Case = 'no rule for the flavour'; Setup = { $global:kpUpdate = Global:KpUpdate 'BLOCKED' 'This script has no kernel package rule for the kernel flavour of 5.15.0-1031-azure-fips.' 'no' }; Says = 'no kernel package rule'; Reason = 'kernelUpdateNoRule' }
        # KERNEL-CHOICE-STOP-ADVICE-1: the package manager never ran - its own
        # reason, never driverBelowFloor's "Choose Update the kernel".
        @{ Case = 'no package manager'; Setup = { $global:kpUpdate = Global:KpUpdate 'BLOCKED' 'The package manager apt-get is not on this machine.' 'no' }; Says = 'is not on this machine'; Reason = 'kernelUpdateNoRule' }
    ) {
        . $Setup
        $ctx = KpMachine $script:rp (KpPlan)
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx }
        $r.PutBack | Should -Not -BeTrue
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be $Reason
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match $Says
        @($global:kpCalls) | Should -Not -Contain 'stop'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $ctx.VmId } {
            param($rp, $id)
            $rec = (Read-VmfStateDoc -RunPath $rp -VmId $id).captured.kernelUpdate
            $rec.result | Should -Be 'stopped'
            Test-VmfKernelPutBackPending -Doc (Read-VmfStateDoc -RunPath $rp -VmId $id) | Should -BeFalse
        }
    }

    It '<Case>: the machine goes back to its pristine copy' -TestCases @(
        @{ Case = 'the package manager failed'; Setup = { $global:kpUpdate = Global:KpUpdate 'BLOCKED' 'apt-get could not install linux-azure (exit code 100): E: Unable to locate package'; }; Says = 'exit code 100'; Restart = $false }

        @{ Case = 'the machine did not start again'; Setup = { $global:kpStartFails = $true }; Says = 'AllocationFailed'; Restart = $true }
        @{ Case = 'the agent did not come back'; Setup = { $global:kpAgentFails = $true }; Says = 'did not report Ready'; Restart = $true }
        @{ Case = 'the driver is still missing'; Setup = { $global:kpAfter = Global:KpMana '5.15.0-1031-azure' $true }; Says = 'not on the installed kernel'; Restart = $true }
    ) {
        . $Setup
        $ctx = KpMachine $script:rp (KpPlan)
        $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepGuestPrep -Context $ctx }
        $r.PutBack | Should -BeTrue
        $r.Reason | Should -Be 'kernelUpdateFailed'
        $r.Detail | Should -Match $Says
        (@($global:kpCalls) -contains 'stop') | Should -Be $Restart
        @($global:kpScripts) | Should -Not -Contain 'nvme-fix.sh' -Because 'a machine whose update failed is never prepared'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $ctx.VmId } {
            param($rp, $id)
            $rec = (Read-VmfStateDoc -RunPath $rp -VmId $id).captured.kernelUpdate
            $rec.result | Should -Be 'failed'
            $rec.error | Should -Not -BeNullOrEmpty
            $rec.putBackUtc | Should -BeNullOrEmpty -Because 'the engine loop puts it back, then says when'
        }
    }
}

Describe 'MANA-LINUX-KERNEL-1: the engine puts the machine back, and a stopped worker resumes' {
    BeforeAll {
        function Global:KrPlan {
            [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/krvm'
                wave = 'w1'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
                    sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'; platformManaged = $false }
                target = [pscustomobject]@{ size = 'Standard_D2ds_v6'; diskArch = 'nvme-temp'; controller = 'NVMe' }
                path = 'A'
                policy = [pscustomobject]@{ onDriverBelowFloor = 'updateKernel'; onDDataFound = 'stop' }
            }
        }
        # A machine at GUEST_PREP with its pristine copy, and an optional record.
        function Global:KrAtPrep($rp, $Record) {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; plan = (Global:KrPlan); rec = $Record } {
                param($rp, $plan, $rec)
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'kr-test'
                New-VmfStateDoc -RunPath $rp -RunId 'kr-test' -VmId $ctx.VmId | Out-Null
                Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ size = 'Standard_D2ds_v4'; dataDisks = @()
                        nics = @([pscustomobject]@{ id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic0'; primary = $true; acceleratedNetworking = $true }) } }
                if ($rec) { Save-VmfKernelUpdateRecord -Context $ctx -Record $rec }
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId
                $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ pristineSnapshotId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/krvm-pristine'; pristineSnapshotLocked = $true; snapshotId = $null; cloneVmId = $null }) -Force
                $null = Complete-VmfTestCapture $doc
                Write-VmfStateDoc -RunPath $rp -Document $doc
                Add-VmfStateTransition -RunPath $rp -VmId $ctx.VmId -NewState 'PRECHECK' -Outcome ok | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $ctx.VmId -NewState 'SAFETY_PRISTINE' -Outcome ok | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $ctx.VmId -NewState 'GUEST_PREP' -Outcome ok | Out-Null
                $ctx.VmId
            }
        }
    }
    AfterAll { Remove-Item 'function:\KrPlan', 'function:\KrAtPrep' -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:rp = Join-Path $script:work ("kr-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'kr-test' | Out-Null }
        $global:krScripts = [System.Collections.Generic.List[string]]::new()
        $global:krUpdate = 'BLOCKED'
        $global:krModuleNow = $false
        $global:krRolledBack = 0
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfRollback { $global:krRolledBack++; $global:krGuestOnly = [bool]$GuestOnly; if ($global:krRollbackFails) { throw 'Conflict: <placeholder>' } }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            $global:krScripts.Add($ScriptName)
            switch ($ScriptName) {
                'mana-check.sh' {
                    $k = if ($global:krModuleNow) { '5.15.0-1102-azure' } else { '5.15.0-1031-azure' }
                    return [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1.1.0'; os = 'ubuntu'; result = 'READY'; warnings = @()
                        checks = @([pscustomobject]@{ name = 'mana module available'; status = 'PASS'; detail = 'modinfo mana' })
                        facts = [pscustomobject]@{ os = 'Linux'; kernelVersion = $k; distroId = 'ubuntu'; distroVersion = '22.04'; fabric = 'mlx5' } }
                }
                'kernel-update.sh' {
                    $o = [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1.0.0'; os = 'ubuntu'; result = $global:krUpdate; warnings = @()
                        checks = @([pscustomobject]@{ name = 'kernel installed'; status = 'INFO'; detail = '5.15.0-1102-azure' }) }
                    if ($global:krUpdate -eq 'FIXED') { $global:krModuleNow = $true } else { $o | Add-Member -NotePropertyName error -NotePropertyValue 'apt-get could not install linux-azure (exit code 100)' }
                    return $o
                }
                default { return [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1.0.0'; os = 'ubuntu'; result = 'READY'; warnings = @(); checks = @() } }
            }
        }
    }
    AfterEach { Remove-Variable krScripts, krUpdate, krModuleNow, krRolledBack, krRollbackFails, krGuestOnly -Scope Global -ErrorAction SilentlyContinue }

    It 'a failed update ends FAILED_ROLLED_BACK, restored, with its own reason - and the record says when it went back' {
        $id = KrAtPrep $script:rp $null
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (Global:KrPlan) } {
            param($rp, $plan) Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'kr-test' }
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'kernelUpdateFailed'
        $last.machineState | Should -Be 'restored'
        $last.detail | Should -Match 'exit code 100'
        $global:krRolledBack | Should -Be 1
        # PREP-ROLLBACK-1: the disks only - the hardware is as it was in GUEST_PREP.
        $global:krGuestOnly | Should -BeTrue
        $doc.captured.kernelUpdate.result | Should -Be 'failed'
        $doc.captured.kernelUpdate.putBackUtc | Should -Not -BeNullOrEmpty
        @($global:krScripts) | Should -Not -Contain 'nvme-fix.sh'
    }

    It 'PERF-TELEMETRY-ENGINE-1: the fail line of the step that asks for the put-back carries its call times' {
        $id = KrAtPrep $script:rp $null
        $null = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (Global:KrPlan) } {
            param($rp, $plan) Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'kr-test' }
        $lines = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $id } {
            param($rp, $id) @(Read-VmfEvents -RunPath $rp -VmId $id -Step 'GUEST_PREP' | Where-Object { $_.outcome -eq 'fail' -and $null -ne $_.PSObject.Properties['durationSec'] }) })
        $lines.Count | Should -Be 1
        $lines[0].calls.v | Should -Be 1 -Because 'the step changed the machine and stopped; its line holds its run store and ARM times'
        InModuleScope VmMigrationFactory { $script:VmfCallTimings | Should -BeNullOrEmpty -Because 'the put-back runs after the record ended' }
    }

    It 'a put-back that fails ends FAILED_NEEDS_ATTENTION, changed - the one state that cannot claim as it was' {
        $global:krRollbackFails = $true
        KrAtPrep $script:rp $null | Out-Null
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (Global:KrPlan) } {
            param($rp, $plan) Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'kr-test' }
        $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        @($doc.history)[-1].reasonCode | Should -Be 'rollbackFailed'
        @($doc.history)[-1].machineState | Should -Be 'changed'
    }

    It 'KILLED during the put-back: the next worker puts it back, and never updates it again' {
        KrAtPrep $script:rp ([ordered]@{ result = 'failed'; kernelBefore = '5.15.0-1031-azure'; error = 'The machine did not start again.'; startedUtc = '2026-10-05T10:00:00Z' }) | Out-Null
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (Global:KrPlan) } {
            param($rp, $plan) Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'kr-test' }
        @($global:krScripts) | Should -Not -Contain 'kernel-update.sh'
        $global:krRolledBack | Should -Be 1
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        @($doc.history)[-1].reasonCode | Should -Be 'kernelUpdateFailed'
        $doc.captured.kernelUpdate.putBackUtc | Should -Not -BeNullOrEmpty
    }

    It 'PREP-ROLLBACK-1: the put-back is the disks-only rollback, with its checkpoint; KILLED inside it, the next worker finishes it once and never visits the step' {
        KrAtPrep $script:rp ([ordered]@{ result = 'failed'; kernelBefore = '5.15.0-1031-azure'; error = 'The machine did not start again.'; startedUtc = '2026-10-05T10:00:00Z' }) | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (Global:KrPlan) } {
            param($rp, $plan)
            Set-VmfRollbackPending -Context (New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'kr-test') -Kind 'disks' -State 'GUEST_PREP' -ReasonCode 'kernelUpdateFailed' -Detail 'The machine did not start again.'
        }
        Mock -ModuleName VmMigrationFactory Invoke-VmfRollback { $global:krRolledBack++; $global:krGuestOnly = [bool]$GuestOnly }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (Global:KrPlan) } {
            param($rp, $plan) Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'kr-test' }
        $global:krRolledBack | Should -Be 1 -Because 'one rollback, never two'
        $global:krGuestOnly | Should -BeTrue -Because 'the hardware is as it was in GUEST_PREP: a Path B machine is never rebuilt to undo a kernel'
        @($global:krScripts).Count | Should -Be 0 -Because 'the step is not run again'
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        @($doc.history)[-1].reasonCode | Should -Be 'kernelUpdateFailed'
        $doc.captured.kernelUpdate.putBackUtc | Should -Not -BeNullOrEmpty
        $doc.PSObject.Properties['rollbackPending'] | Should -BeNullOrEmpty
        Remove-Variable krGuestOnly -Scope Global -ErrorAction SilentlyContinue
    }

    It 'KILLED after the restart: the next worker reads the driver there, finishes the record, and goes on' {
        $global:krModuleNow = $true
        KrAtPrep $script:rp ([ordered]@{ result = 'running'; kernelBefore = '5.15.0-1031-azure'; startedUtc = '2026-10-05T10:00:00Z' }) | Out-Null
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (Global:KrPlan) } {
            param($rp, $plan)
            Invoke-VmfStepGuestPrep -Context (New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'kr-test') }
        $r.Next | Should -Be 'STOPPED'
        @($global:krScripts) | Should -Not -Contain 'kernel-update.sh'
        $rec = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = (Global:KrPlan).vmId } { param($rp, $id) (Read-VmfStateDoc -RunPath $rp -VmId $id).captured.kernelUpdate }
        $rec.result | Should -Be 'updated'
        $rec.kernelBefore | Should -Be '5.15.0-1031-azure'
        $rec.kernelAfter | Should -Be '5.15.0-1102-azure'
    }

    It 'KILLED before the restart: the update runs again, and the record keeps the kernel the machine had' {
        $global:krUpdate = 'FIXED'
        KrAtPrep $script:rp ([ordered]@{ result = 'running'; kernelBefore = '5.15.0-1020-azure'; startedUtc = '2026-10-05T10:00:00Z' }) | Out-Null
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (Global:KrPlan) } {
            param($rp, $plan)
            Invoke-VmfStepGuestPrep -Context (New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'kr-test') }
        $r.Next | Should -Be 'STOPPED'
        @($global:krScripts) | Should -Contain 'kernel-update.sh'
        $rec = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = (Global:KrPlan).vmId } { param($rp, $id) (Read-VmfStateDoc -RunPath $rp -VmId $id).captured.kernelUpdate }
        $rec.result | Should -Be 'updated'
        $rec.kernelBefore | Should -Be '5.15.0-1020-azure' -Because 'the first reading of this attempt, not the second'
        (Get-Date $rec.startedUtc).ToUniversalTime() | Should -Be ([datetime]::Parse('2026-10-05T10:00:00Z').ToUniversalTime()) -Because 'the start of this attempt''s update, kept'
    }

    It 'KILLED after the restart, and the new kernel does not start: the next worker puts it back (review finding 2)' {
        $global:krAgentFails = $true
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { if ($global:krAgentFails) { throw "VM 'krvm' agent did not report Ready within 600s - possible boot failure." } }
        KrAtPrep $script:rp ([ordered]@{ result = 'running'; kernelBefore = '5.15.0-1031-azure'; startedUtc = '2026-10-05T10:00:00Z' }) | Out-Null
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (Global:KrPlan) } {
            param($rp, $plan) Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'kr-test' }
        @($global:krScripts) | Should -Not -Contain 'kernel-update.sh'
        $global:krRolledBack | Should -Be 1
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        @($doc.history)[-1].reasonCode | Should -Be 'kernelUpdateFailed'
        @($doc.history)[-1].detail | Should -Match 'did not answer after the kernel update'
        Remove-Variable krAgentFails -Scope Global -ErrorAction SilentlyContinue
    }

    It 'a person''s new attempt removes the record; the automatic put-back keeps it' {
        KrAtPrep $script:rp ([ordered]@{ result = 'failed'; kernelBefore = '5.15.0-1031-azure'; error = 'x'; putBackUtc = '2026-10-05T10:30:00Z' }) | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = (Global:KrPlan).vmId } {
            param($rp, $id)
            Clear-VmfRetryState -RunPath $rp -VmId $id -From 'PRECHECK'
            (Read-VmfStateDoc -RunPath $rp -VmId $id).captured.kernelUpdate.result | Should -Be 'failed' -Because 'the automatic rollback keeps the record of what was done'
            Clear-VmfRetryState -RunPath $rp -VmId $id -From 'PRECHECK' -NewAttempt
            (Read-VmfStateDoc -RunPath $rp -VmId $id).captured.PSObject.Properties['kernelUpdate'] | Should -BeNullOrEmpty
        }
    }

    It 'the record meets its contract' {
        KrAtPrep $script:rp $null | Out-Null
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = (Global:KrPlan) } {
            param($rp, $plan) Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'kr-test' }
        $sample = Get-Content (Join-Path $script:schemas 'samples' 'vm-state.sample.json') -Raw | ConvertFrom-Json -Depth 30
        $sample.captured | Add-Member -NotePropertyName kernelUpdate -NotePropertyValue $doc.captured.kernelUpdate -Force
        ($sample | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:schemas 'vm-state.schema.json') | Should -BeTrue
    }
}

Describe 'MANA-LINUX-KERNEL-1: a rollback puts the old kernel back on the record' {
    It 'a later rollback says the old kernel is back on the record (review finding 11)' {
        $rp = Join-Path $script:work ("krb-{0}" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
            param($rp)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/krbvm'; wave = 'w1'
                assessment = [pscustomobject]@{ os = 'Linux'; sourceSize = 'Standard_D2ds_v4' }; target = [pscustomobject]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe' }
                path = 'A'; policy = [pscustomobject]@{ onDriverBelowFloor = 'updateKernel' } }
            Initialize-VmfRun -RunPath $rp -RunId 'krb-test' | Out-Null
            $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'krb-test'
            New-VmfStateDoc -RunPath $rp -RunId 'krb-test' -VmId $ctx.VmId | Out-Null
            Save-VmfKernelUpdateRecord -Context $ctx -Record ([ordered]@{ result = 'updated'; kernelBefore = '5.15.0-1031-azure'; kernelAfter = '5.15.0-1102-azure' })
            Mock Invoke-VmfAzOperation { }
            Mock Get-VmfPutBackCapture { [pscustomobject]@{ size = 'Standard_D2ds_v4'; controller = 'SCSI'; location = 'centralus'; nics = @(); dataDisks = @(); osDisk = $null; capacityReservationGroupId = $null } }
            Mock Get-VmfRetiredRollbackRefusal { $null }
            Mock Restore-VmfCapturedDiskTypes { 0 }
            Mock Assert-VmfSizeTakesKeptDisks { }
            Mock Get-VmfSourceAcceleratedNetworking { $null }
            Mock Restore-VmfCapturedAcceleratedNetworking { 0 }
            Mock Get-VmfDataRestorePlan { @{ Restore = @(); Kept = @() } }
            Invoke-VmfRollback -Context $ctx
            (Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId).captured.kernelUpdate.putBackUtc | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'MANA-LINUX-KERNEL-1: the guest script' {
    BeforeAll {
        $script:sh = Join-Path $script:repoRoot 'src' 'guest' 'linux' 'kernel-update.sh'
        $script:shCode = Get-VmfCodeOnly -Path $script:sh -Language Shell
    }

    It 'runs under bash, not sh: its first line says so' {
        (Get-Content $script:sh -TotalCount 1) | Should -Be '#!/bin/bash'
    }

    It 'is in the manifest with its hash' {
        $m = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'manifest.json') -Raw | ConvertFrom-Json
        $entry = @($m.scripts) | Where-Object name -eq 'kernel-update.sh'
        $entry.os | Should -Be 'linux'
        $entry.sha256 | Should -Be (Get-FileHash $script:sh -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    It 'never adds a repository - only the ones the machine already uses' {
        $script:shCode | Should -Not -Match 'add-apt-repository|apt-add-repository|sources\.list|zypper\s+(ar|addrepo)\b|config-manager|yum-config-manager|\.repo\b|curl|wget'
    }

    It 'asks each distribution for its own supported kernel package' {
        foreach ($pkg in 'PKG="linux-azure"', 'PKG="linux-image-cloud-$ARCH"', 'PKG="kernel-uek"', 'PKG="kernel-azure"', 'PKG="kernel-default"', 'PKG="kernel"') {
            $script:shCode | Should -Match ([regex]::Escape($pkg))
        }
    }

    It 'reports facts the contract declares, and never judges MANA itself' {
        $script:shCode | Should -Not -Match '\bmodinfo\b|\bmana\b'
        $script:shCode | Should -Match 'vmf\.guest/2'
    }
}
