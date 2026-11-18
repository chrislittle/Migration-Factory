#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# MANA-WIN-3, 2026-10-25: nothing warned that a Windows machine must reach
# download.microsoft.com for its MANA driver install.
#
# MANA-WIN-1 made GUEST_PREP install Microsoft's MANA driver on a Windows
# machine whose driver store has none, when its target can give MANA and its
# primary interface keeps accelerated networking on after the move
# (Test-VmfManaDriverInstallWanted). Install-ManaDriver.ps1 downloads the
# pinned package from download.microsoft.com. A machine that cannot reach it
# stops with manaDriverInstallFailed - and the first anybody heard of the
# need was that stop. Only the manual's "how a machine moves" said it.
#
# The owner kept only the warning in 1.0 (V1-TRIAGE-1, 2026-10-20):
#   - at ASSESSMENT time, a finding under "What to check before the move"
#     (assessment-reasons.json warnings). The scan reads Azure, not the
#     driver store, so it cannot tell which machines need the download -
#     every Windows machine carries it, as every Linux machine carries the
#     kernel floor item (DRIVER-WARN-1). Unknown is never a no.
#   - at PLAN time, a note on each Windows plan entry whose move runs the
#     install (planNotes), by the engine's own rule, shown under the machine
#     on the wizard's Run it step.
# What happens when the download fails is read from the code, never invented:
# the stop reason manaDriverInstallFailed, before the machine is stopped.
# Windows has no published MANA driver floor and an in-box driver is normal
# (AN-KEEP-1), so no word here may say a machine "cannot drive MANA".

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'mdd'

    $script:code = 'mana-driver-download'
    $script:reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
    $script:stops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
    $script:stopTitle = [string](@($script:stops.reasons) | Where-Object { [string]$_.code -eq 'manaDriverInstallFailed' } | Select-Object -First 1).title

    function Global:MddRow {
        param([string]$Os = 'Windows', [string]$ImagePublisher = 'MicrosoftWindowsServer', [string]$ImageSku = '2022-datacenter-g2')
        [pscustomobject]@{
            id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
            name = 'vm1'; resourceGroup = 'rg'; location = 'centralus'; zones = @()
            sku = 'Standard_D2ds_v4'; os = $Os; gen = 'V2'; diskController = 'SCSI'
            imagePublisher = $ImagePublisher; imageSku = $ImageSku; vmssId = ''
            hibernationEnabled = $false; securityType = ''; dataDiskCount = 2
            tags = $null; identityType = 'None'; identityPrincipalId = ''
        }
    }
    function Global:MddSku {
        [pscustomobject]@{ name = 'Standard_D2ds_v4'; family = 'StandardDDSv4Family'
            capabilities = @(@{ name = 'MaxResourceVolumeMB'; value = '76800' }, @{ name = 'vCPUs'; value = '2' })
            restrictions = @() }
    }
    function Global:MddRecord($Row) {
        & (Get-Module VmMigrationFactory) { param($v, $s) Get-VmfAssessmentRecord -Vm $v -SkuEntry $s } $Row (MddSku)
    }

    # A plan entry as the plan stores it.
    function Global:MddEntry {
        param([string]$Os = 'Windows', [string]$Size = 'Standard_D2ds_v6', [string]$Path = 'A', [object]$Primary = $false,
              [string]$AnSetting = '', [string[]]$Notes = @())
        $policy = [ordered]@{ safetyCopy = 'pristine'; capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop' }
        if ($AnSetting) { $policy.acceleratedNetworking = $AnSetting }
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
            wave = 'w1'; path = $Path
            assessment = [pscustomobject]@{ os = $Os; sourceSize = 'Standard_D2ds_v4'; nicCount = 1
                acceleratedNicCount = $(if ($null -eq $Primary) { $null } elseif ($Primary) { 1 } else { 0 }); primaryNicAccelerated = $Primary }
            target = [pscustomobject]@{ size = $Size; controller = $(if ($Size -match '_v[67]$') { 'NVMe' } else { 'SCSI' }) }
            policy = [pscustomobject]$policy
            planNotes = @($Notes)
        } | ConvertTo-Json -Depth 10 | ConvertFrom-Json -Depth 10
    }
    function Global:MddNote($Entry) {
        InModuleScope VmMigrationFactory -Parameters @{ e = $Entry } { param($e) Get-VmfManaDriverDownloadNote -PlanEntry $e }
    }
    function Global:MddSetNote($Entry) {
        InModuleScope VmMigrationFactory -Parameters @{ e = $Entry } { param($e) Set-VmfManaDriverDownloadNote -PlanEntry $e -Confirm:$false }
    }
}
AfterAll {
    Remove-Item 'function:\MddRow', 'function:\MddSku', 'function:\MddRecord', 'function:\MddEntry', 'function:\MddNote', 'function:\MddSetNote' -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
}

Describe 'MANA-WIN-3: the assessment says that a Windows machine can need download.microsoft.com' {

    It 'a Windows machine carries the finding, under What to check before the move' {
        @((MddRecord (MddRow)).warnings) | Should -Contain $script:code
    }

    It 'an excluded Windows machine does not: it never moves (review)' {
        $row = MddRow
        $row.vmssId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachineScaleSets/ss1'
        $r = MddRecord $row
        $r.classification | Should -Be 'Excluded'
        @($r.warnings) | Should -Not -Contain $script:code
    }

    It 'a Windows machine that every size series blocks does not: it cannot move anywhere (review)' {
        # Generation 1 closes v6 and v7; Windows Server 2012 R2 closes v5 too.
        $row = MddRow -ImageSku '2012-R2-Datacenter'
        $row.gen = 'V1'
        $r = MddRecord $row
        @($r.blockers) | Should -Contain 'gen1-requires-redeploy'
        @($r.blockers) | Should -Contain 'windows-version-not-proven'
        @($r.warnings) | Should -Not -Contain $script:code
    }

    It 'a Blocked Windows machine with one series still open has it: Generation 1 moves to v5' {
        $row = MddRow -ImageSku '2019-datacenter'
        $row.gen = 'V1'
        $r = MddRecord $row
        $r.classification | Should -Be 'Blocked'
        @($r.blockers) | Should -Not -Contain 'windows-version-not-proven'
        @($r.warnings) | Should -Contain $script:code
    }

    It 'a Linux machine does not: its MANA driver is in its kernel (AN-KEEP-1)' {
        @((MddRecord (MddRow -Os 'Linux' -ImagePublisher 'Canonical' -ImageSku '22_04-lts-gen2')).warnings) | Should -Not -Contain $script:code
    }

    It 'it is a warning, never a blocker or prep: the machine can still move, and the classification does not change' {
        $script:reasons.warnings.PSObject.Properties.Name | Should -Contain $script:code
        $script:reasons.blockers.PSObject.Properties.Name | Should -Not -Contain $script:code
        $script:reasons.prep.PSObject.Properties.Name | Should -Not -Contain $script:code
        $r = MddRecord (MddRow)
        @($r.blockers) | Should -Not -Contain $script:code
        @($r.prepNeeded) | Should -Not -Contain $script:code
        $r.classification | Should -Be 'ReadyAfterPrep'
    }

    It 'it applies to every series that can give MANA: v5 (Intel), v6 and v7' {
        @($script:reasons.warnings.$($script:code).appliesTo) | Should -Be @('v5', 'v6', 'v7')
    }

    It 'the words name the host, HTTPS, MANA, and the stop the engine really gives' {
        $w = $script:reasons.warnings.$($script:code)
        $all = "$($w.title) $($w.meaning) $($w.whatToDo)"
        $all | Should -Match 'download\.microsoft\.com'
        $all | Should -Match 'HTTPS'
        $all | Should -Match 'Microsoft Azure Network Adapter \(MANA\)'
        $script:stopTitle | Should -Not -BeNullOrEmpty -Because 'the stop reason manaDriverInstallFailed is in stop-reasons.json'
        $w.whatToDo | Should -Match ([regex]::Escape($script:stopTitle))
        $w.docs.url | Should -Be 'https://learn.microsoft.com/en-us/azure/virtual-network/accelerated-networking-mana-windows'
    }

    It 'the words never say that Windows cannot drive MANA, and never invent a driver version' {
        $w = $script:reasons.warnings.$($script:code)
        "$($w.title) $($w.meaning) $($w.whatToDo)" | Should -Not -Match '(?i)cannot (drive|use) MANA|minimum driver|driver version \d'
        $w.meaning | Should -Match '(?i)driver store'
    }

    It 'the generated reference page carries it' {
        $page = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'assessment-findings.md') -Raw
        $page | Should -Match ([regex]::Escape([string]$script:reasons.warnings.$($script:code).title))
    }
}

Describe 'MANA-WIN-3: the plan names each Windows machine whose move runs the MANA driver install' {

    It 'a Windows move to v6 that turns accelerated networking on gets the note' {
        MddNote (MddEntry) | Should -Not -BeNullOrEmpty
    }

    It 'a Windows move to v6 with accelerated networking on already gets the note' {
        MddNote (MddEntry -Primary $true) | Should -Not -BeNullOrEmpty
    }

    It 'a Windows move to an Intel v5 size gets the note: MANA reaches Intel v5 hosts' {
        MddNote (MddEntry -Size 'Standard_D2s_v5') | Should -Not -BeNullOrEmpty
    }

    It 'a Windows move to an AMD v5 size gets none: an AMD v5 size never gives MANA' {
        MddNote (MddEntry -Size 'Standard_D2as_v5') | Should -BeNullOrEmpty
    }

    It 'a Windows move to a size the product cannot read gets the note: unknown is never a no, as in GUEST_PREP' {
        InModuleScope VmMigrationFactory { Test-VmfTargetMayUseMana -SizeName 'Standard_X9_v9' } | Should -BeNullOrEmpty
        # Accelerated networking on already, which such a move keeps on.
        MddNote (MddEntry -Size 'Standard_X9_v9' -Primary $true) | Should -Not -BeNullOrEmpty
    }

    It 'a Linux move gets none' {
        MddNote (MddEntry -Os 'Linux') | Should -BeNullOrEmpty
    }


    It 'a move that keeps accelerated networking off gets none' {
        MddNote (MddEntry -AnSetting 'preserve' -Primary $false) | Should -BeNullOrEmpty
    }

    It 'a move that keeps a primary interface the scan did not read gets the note: unknown is never a no' {
        MddNote (MddEntry -AnSetting 'preserve' -Primary $null) | Should -Not -BeNullOrEmpty
    }

    It 'a machine the plan does not move gets none: <path>' -ForEach @(@{ path = 'MANUAL' }, @{ path = 'EXCLUDED' }) {
        MddNote (MddEntry -Path $path) | Should -BeNullOrEmpty
    }

    It 'the note asks the engine''s own rule (Test-VmfManaDriverInstallWanted): with that rule false, no note' {
        Mock -ModuleName VmMigrationFactory Test-VmfManaDriverInstallWanted { $false }
        MddNote (MddEntry) | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfManaDriverInstallWanted -Times 1 -Exactly
    }

    It 'the note names the host, HTTPS, the stop the engine really gives, and that the machine keeps its size' {
        $note = MddNote (MddEntry)
        $note | Should -Match 'download\.microsoft\.com'
        $note | Should -Match 'HTTPS'
        $note | Should -Match ([regex]::Escape($script:stopTitle.ToLowerInvariant().Substring(4)))
        $note | Should -Match 'keeps its current size'
        $note | Should -Not -Match '(?i)cannot (drive|use) MANA'
    }

    It 'every sentence of the note is 25 words or fewer (rule 10)' {
        foreach ($s in ((MddNote (MddEntry)) -split '(?<=\.)\s+' | Where-Object { $_ })) {
            @($s -split '\s+' | Where-Object { $_ }).Count | Should -BeLessOrEqual 25 -Because $s
        }
    }
}

Describe 'MANA-WIN-3: the note is written on the entry, and follows the entry' {

    It 'a stored entry gets the note after the notes it had' {
        $e = MddEntry -Notes @('Another note.')
        MddSetNote $e
        @($e.planNotes) | Should -HaveCount 2
        @($e.planNotes)[0] | Should -BeExactly 'Another note.'
        @($e.planNotes)[1] | Should -BeExactly (MddNote $e)
    }

    It 'a plan entry being built (a dictionary) gets the note' {
        $e = (MddEntry) | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable
        MddSetNote $e
        @($e['planNotes']) | Should -HaveCount 1
        @($e['planNotes'])[0] | Should -Match 'download\.microsoft\.com'
    }

    It 'the same note again leaves the text as it was - a changed entry voids the approval of its wave' {
        $e = MddEntry
        MddSetNote $e
        $before = $e | ConvertTo-Json -Depth 10
        MddSetNote $e
        ($e | ConvertTo-Json -Depth 10) | Should -BeExactly $before
    }

    It 'an entry with no notes, and none to add, gains no planNotes field' {
        $e = (MddEntry -Os 'Linux')
        $e.PSObject.Properties.Remove('planNotes')
        $before = $e | ConvertTo-Json -Depth 10
        MddSetNote $e
        ($e | ConvertTo-Json -Depth 10) | Should -BeExactly $before
    }

    It 'an entry whose move no longer runs the install loses the note, and keeps its other notes' {
        $e = MddEntry -Notes @('Another note.')
        MddSetNote $e
        $e.policy | Add-Member -NotePropertyName acceleratedNetworking -NotePropertyValue 'preserve' -Force
        $e.assessment.primaryNicAccelerated = $false
        $e.assessment.acceleratedNicCount = 0
        MddSetNote $e
        @($e.planNotes) | Should -Be @('Another note.')
    }
}

Describe 'MANA-WIN-3: every plan writer records the note' {
    BeforeAll {
        function Global:MddId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
        function Global:MddSkus([string]$File) {
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
        $script:skus = @(MddSkus 'old-size-catalog-centralus.json') + @(MddSkus 'bsv2-catalog-centralus.json')
        function Global:MddVm {
            param([string]$Name, [string]$Size, [string]$Gen = 'V2', [string]$Os = 'Linux')
            $sku = @($script:skus | Where-Object Name -EQ $Size)[0]
            $tempMb = [int](@($sku.Capabilities | Where-Object { $_.Name -eq 'MaxResourceVolumeMB' })[0].Value)
            [pscustomobject]@{
                vmId = (MddId $Name); name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @(); gen = $Gen
                os = $Os; osVersion = $(if ($Os -eq 'Windows') { '2019-datacenter' } else { 'custom' })
                runningOsName = $(if ($Os -eq 'Linux') { 'ubuntu' } else { '' }); runningOsVersion = $(if ($Os -eq 'Linux') { '22.04' } else { '' })
                classification = 'ReadyAfterPrep'; blockers = @(if ($Gen -eq 'V1') { 'gen1-requires-redeploy' }); prepNeeded = @()
                warnings = @(if ($Os -eq 'Windows') { 'mana-driver-download' })
                sourceSize = $Size; sourceDiskArch = $(if ($tempMb -gt 0) { 'scsi-temp' } else { 'diskless' }); sourceTempDisks = $(if ($tempMb -gt 0) { 1 } else { 0 })
                diskController = $(if ($Gen -eq 'V1') { '' } else { 'SCSI' }); dataDiskCount = 1; nicCount = 1
                acceleratedNicCount = 0; primaryNicAccelerated = $false; platformManaged = $false; iacManaged = $false
                hibernationEnabled = $false; availabilitySetId = ''; identityType = 'None'; tags = @{ app = $Name }
            }
        }
        function Global:MddPlanned([object[]]$Vms, [hashtable]$Options) {
            $rp = Join-Path $script:temp "mdd-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $rp -Leaf); generatedUtc = '2026-10-25T00:00:00Z'
                scope = @{ subscriptions = @() }; summary = @{}; vms = @($Vms) }
            InModuleScope VmMigrationFactory -Parameters @{ r = $rp; d = $doc } {
                param($r, $d)
                Initialize-VmfRun -RunPath $r -RunId (Split-Path $r -Leaf) -Kind 'assessment' | Out-Null
                Write-VmfStoreJson -RunPath $r -RelPath 'assessment.json' -Document $d -Depth 24
            }
            Approve-VmfAssessment -RunPath $rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
            New-VmfTargetAdvice -AssessmentPath (Join-Path $rp 'assessment.json') | Out-Null
            $adviceVersion = InModuleScope VmMigrationFactory -Parameters @{ r = $rp } {
                param($r) Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $r -RelPath 'target-advice.json')) }
            Set-VmfTestTargetChoice -RunPath $rp -Default 'current' -ExpectedAdviceVersion $adviceVersion -ExpectedChoicesVersion '' `
                -Choices @($Options.Keys | ForEach-Object { @{ vmId = (MddId $_); option = $Options[$_] } }) `
                -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
            New-VmfPlan -AssessmentPath (Join-Path $rp 'assessment.json') -OutPath "$rp-migration" | Out-Null
            "$rp-migration"
        }
        function Global:MddPlanEntry([string]$Mig, [string]$Name) {
            @((Get-Content (Join-Path $Mig 'plan.json') -Raw | ConvertFrom-Json -Depth 40).entries) | Where-Object vmId -EQ (MddId $Name)
        }
        $script:noteText = MddNote (MddEntry)
    }
    AfterAll {
        Remove-Item 'function:\MddId', 'function:\MddSkus', 'function:\MddVm', 'function:\MddPlanned', 'function:\MddPlanEntry' -ErrorAction SilentlyContinue
    }

    Context 'the plan (New-VmfPlan)' {
        BeforeAll {
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:skus }
            $script:mig = MddPlanned -Vms @(
                (MddVm -Name 'win-b2' -Size 'Standard_B2ms' -Gen 'V1' -Os 'Windows'),
                (MddVm -Name 'lin-b2' -Size 'Standard_B2s')
            ) -Options @{ 'win-b2' = 'v5'; 'lin-b2' = 'v5' }
        }

        It 'the Windows machine moving to an Intel Bsv2 size has the note' {
            $e = MddPlanEntry $script:mig 'win-b2'
            $e.target.size | Should -Be 'Standard_B2s_v2'
            @($e.planNotes) | Should -Contain $script:noteText
        }

        It 'the Linux machine has none' {
            @((MddPlanEntry $script:mig 'lin-b2').planNotes) | Should -Not -Contain $script:noteText
        }

        It 'the entry still matches the contract' {
            $schema = Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json'
            Test-Json -Json ((MddPlanEntry $script:mig 'win-b2') | ConvertTo-Json -Depth 30) -SchemaFile $schema -ErrorAction Stop | Should -BeTrue
        }
    }

    Context 'a target changed in the wave editor (Set-VmfMachineTarget)' {
        BeforeEach {
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:skus }
            $script:mig2 = MddPlanned -Vms @((MddVm -Name 'win-d2' -Size 'Standard_D2_v2' -Os 'Windows')) -Options @{ 'win-d2' = 'v5' }
        }

        It 'keeps the note on the new target: it rewrote planNotes with the retirement warning alone' {
            @((MddPlanEntry $script:mig2 'win-d2').planNotes) | Should -Contain $script:noteText
            (Set-VmfMachineTarget -RunPath $script:mig2 -VmId (MddId 'win-d2') -Option v6 -ChangedBy 'operator@example.com' -Confirm:$false).Applied | Should -BeTrue
            $after = MddPlanEntry $script:mig2 'win-d2'
            $after.policy.targetGeneration | Should -Be 'v6'
            @($after.planNotes) | Should -Contain $script:noteText
        }
    }

    Context 'a decision that sets accelerated networking (Resolve-VmfDecision)' {
        BeforeEach {
            $script:vm = MddId 'dec-01'
            $script:rp = Join-Path $script:temp "mdd-dec-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vm } {
                param($rp, $vm)
                Initialize-VmfRun -RunPath $rp -RunId 'mdd-dec' | Out-Null
                New-VmfStateDoc -RunPath $rp -RunId 'mdd-dec' -VmId $vm -Wave 'w1' | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'NEEDS_DECISION' -Outcome ok -ReasonCode 'acceleratedNetworkingRequired' `
                    -Detail 'Microsoft requires accelerated networking on Standard_D2ds_v6' | Out-Null
            }
            $entry = [ordered]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm; wave = 'w1'; path = 'A'
                assessment = [ordered]@{ os = 'Windows'; sourceSize = 'Standard_D2ds_v4'; nicCount = 1; acceleratedNicCount = 0; primaryNicAccelerated = $false }
                target = [ordered]@{ size = 'Standard_D2ds_v6'; diskArch = 'nvme-temp'; controller = 'NVMe' }
                policy = [ordered]@{ safetyCopy = 'pristine'; capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop'; acceleratedNetworking = 'preserve' }
                planNotes = @()
                acceleratedNetworkingOutcome = [ordered]@{ turnsOn = $false; unknownWhy = $null }
            }
            $script:pp = Join-Path $script:rp 'plan.json'
            [ordered]@{ schemaVersion = 5; assessmentRunId = 'mdd-dec'; entries = @($entry) } | ConvertTo-Json -Depth 12 | Set-Content $script:pp -Encoding utf8NoBOM
            Confirm-VmfWaveOptions -RunPath $script:rp -PlanPath $script:pp -Wave 'w1' -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
            Approve-VmfPlan -RunPath $script:rp -PlanPath $script:pp -Note 'approved' -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
            Confirm-VmfRunAcknowledgement -RunPath $script:rp -AcknowledgedBy 'operator@example.com' | Out-Null
        }

        It 'the decision ensureOn makes the move run the install, and the entry says so' {
            Resolve-VmfDecision -RunPath $script:rp -PlanPath $script:pp -VmId $script:vm -PolicyOverride @{ acceleratedNetworking = 'ensureOn' } `
                -Note 'go' -ResolvedBy 'approver@example.com' -ResolvedRoles @('Vmf.Approver') | Out-Null
            $e = @((Get-Content $script:pp -Raw | ConvertFrom-Json -Depth 20).entries)[0]
            $e.policy.acceleratedNetworking | Should -Be 'ensureOn'
            @($e.planNotes) | Should -Contain $script:noteText
        }
    }
}
