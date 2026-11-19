#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# STALE-APPROVAL-RACE-1: removing stale approvals could remove a valid one.
#
# Remove-VmfStaleWaveApprovals judged every approval against a plan text its
# caller read before it looked at the approvals, then removed the file with an
# ordinary delete. If another writer saved the plan and an approver approved
# that newer plan in the moment between, the approval was judged against the
# older text and removed - a valid approval gone, and named as out of date.
#
# Now each approval is read FIRST, the plan as stored SECOND, and the delete
# removes the approval only if it still holds the text that was judged
# (PLANVER-2 versions; If-Match on blob storage). A wave save's own removal of
# the waves it changed does the same with the approval it read before writing.
#
# Each test below puts another writer and an approver in the window, through
# the real wave save.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:SarSku([string]$Name) {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V2' }) }
    }
    function Global:SarVm([string]$Name, [string]$Environment) {
        [ordered]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @()
            classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; osVersion = '22_04-lts-gen2'
            sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = 'SCSI'
            dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; iacManaged = $false; hibernationEnabled = $false; availabilitySetId = ''
            identityType = 'None'; tags = @{ environment = $Environment }; blockers = @(); prepNeeded = @()
        }
    }
    function Global:SarPlanPath($mig) { Join-Path $mig 'plan.json' }
    function Global:SarPlanText($mig) { [System.IO.File]::ReadAllText((SarPlanPath $mig)) }
    function Global:SarPlan($mig) { (SarPlanText $mig) | ConvertFrom-Json -Depth 30 }
    # wave-1 holds app-01 and app-02 (dev), wave-2 holds web-01 and web-02 (prod).
    function Global:SarPlanned {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sar-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $vms = @((SarVm 'app-01' 'dev'), (SarVm 'app-02' 'dev'), (SarVm 'web-01' 'prod'), (SarVm 'web-02' 'prod'))
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $rp -Leaf); generatedUtc = '2026-10-01T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}; vms = $vms }
        InModuleScope VmMigrationFactory -Parameters @{ r = $rp; d = $doc } {
            Initialize-VmfRun -RunPath $r -RunId (Split-Path $r -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $r -RelPath 'assessment.json' -Document $d -Depth 24
        }
        $who = @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }
        Approve-VmfAssessment -RunPath $rp -OnBehalfOf $who | Out-Null
        New-VmfTargetAdvice -AssessmentPath (Join-Path $rp 'assessment.json') | Out-Null
        $adviceVersion = InModuleScope VmMigrationFactory -Parameters @{ r = $rp } {
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $r -RelPath 'target-advice.json'))
        }
        Set-VmfTestTargetChoice -RunPath $rp -Default 'current' -ExpectedAdviceVersion $adviceVersion -ExpectedChoicesVersion '' `
            -Choices @($vms | ForEach-Object { @{ vmId = $_.vmId; option = 'v6' } }) -OnBehalfOf $who | Out-Null
        $mig = "$rp-migration"
        New-VmfPlan -AssessmentPath (Join-Path $rp 'assessment.json') -OutPath $mig -WaveStrategy 'tags' -AppGroupTag 'environment' -RequireTargets | Out-Null
        @{ Scan = $rp; Mig = $mig }
    }
    function Global:SarApprove($mig, [string]$Wave) {
        Approve-VmfWave -RunPath $mig -PlanPath (SarPlanPath $mig) -Wave $Wave -Note 'read and approved' `
            -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
    }
    function Global:SarApproveNote($mig, [string]$Wave, [string]$Note) {
        Approve-VmfWave -RunPath $mig -PlanPath (SarPlanPath $mig) -Wave $Wave -Note $Note `
            -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
    }
    function Global:SarEvents($mig) {
        @(Get-Content (Join-Path $mig 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | ForEach-Object { [string]$_.detail })
    }
    function Global:SarApprovalText($mig, [string]$Wave) {
        $file = Join-Path $mig 'approvals' "$Wave.json"
        if (Test-Path $file) { [System.IO.File]::ReadAllText($file) } else { $null }
    }
    function Global:SarVersion([string]$Text, [string]$Wave) {
        InModuleScope VmMigrationFactory -Parameters @{ t = $Text; w = $Wave } { Get-VmfWaveVersion -PlanText $t -Wave $w }
    }
    # Does the approval file of the wave sign the wave as the plan is stored now?
    function Global:SarSignsNow($mig, [string]$Wave) {
        $text = SarApprovalText $mig $Wave
        if (-not $text) { return $false }
        [string]::Equals([string]($text | ConvertFrom-Json).waveVersion, (SarVersion (SarPlanText $mig) $Wave), [System.StringComparison]::Ordinal)
    }
    function Global:SarIds($mig, [string]$Wave) { @((SarPlan $mig).entries | Where-Object { $_.wave -eq $Wave } | ForEach-Object { [string]$_.vmId }) }
    # The wave editor's save, with settings for one wave.
    function Global:SarSave($mig, [hashtable]$Wave1 = @{}, [hashtable]$Wave2 = @{}) {
        $one = [ordered]@{ name = 'wave-1'; vmIds = @(SarIds $mig 'wave-1') }
        foreach ($k in $Wave1.Keys) { $one[$k] = $Wave1[$k] }
        $two = [ordered]@{ name = 'wave-2'; vmIds = @(SarIds $mig 'wave-2') }
        foreach ($k in $Wave2.Keys) { $two[$k] = $Wave2[$k] }
        Set-VmfWavePlan -RunPath $mig -PlanPath (SarPlanPath $mig) -Layout @{ waves = @($one, $two) } -ChangedBy 'operator@example.com' -Confirm:$false
    }
    # Another writer of the plan: a setting changed on every machine of wave-2,
    # written with the plan's own version-checked write.
    function Global:SarOtherWriter($mig, [int]$Days) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig; d = $Days } {
            $pp = Join-Path $m 'plan.json'
            $read = Read-VmfPlanFileVersioned -Path $pp
            foreach ($e in @($read.Plan.entries | Where-Object { $_.wave -eq 'wave-2' })) {
                $e.policy | Add-Member -NotePropertyName keepSnapshotDays -NotePropertyValue $d -Force
            }
            Write-VmfTextDocumentIfVersion -Path $pp -Content ($read.Plan | ConvertTo-Json -Depth 24) -ExpectedVersion $read.Version
        }
    }
}
AfterAll {
    foreach ($fn in 'SarSku', 'SarVm', 'SarPlanPath', 'SarPlanText', 'SarPlan', 'SarPlanned', 'SarApprove', 'SarApprovalText', 'SarApproveNote', 'SarEvents',
                    'SarVersion', 'SarSignsNow', 'SarIds', 'SarSave', 'SarOtherWriter') {
        Remove-Item "function:\$fn" -ErrorAction SilentlyContinue
    }
}

Describe 'STALE-APPROVAL-RACE-1: a removal of stale approvals never removes a valid one' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((SarSku 'Standard_D2ds_v6'), (SarSku 'Standard_D2s_v6'), (SarSku 'Standard_D2ds_v5'), (SarSku 'Standard_D2s_v5')) }
        $script:run = SarPlanned
        $script:mig = $script:run.Mig
        SarApprove $script:mig 'wave-1'
        SarApprove $script:mig 'wave-2'
        $script:injected = $false
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'another writer and an approver act after the save read the plan, while the removal reads the approval: it stays' {
        # The save changes wave-1. As the removal reads wave-2's approval,
        # another writer changes wave-2 and an approver approves that plan.
        Mock -ModuleName VmMigrationFactory Read-VmfStoreText -ParameterFilter { $RelPath -ceq 'approvals/wave-2.json' } {
            if (-not $script:injected) {
                $script:injected = $true
                SarOtherWriter $script:mig 21
                SarApprove $script:mig 'wave-2'
            }
            $file = Join-Path $RunPath 'approvals' 'wave-2.json'
            if (Test-Path $file) { [System.IO.File]::ReadAllText($file) } else { $null }
        }
        # Never removed, so never put back: a put-back would hide a removal
        # judged against the plan read before the approval.
        $script:putBack = $false
        Mock -ModuleName VmMigrationFactory Write-VmfStoreTextExclusive -ParameterFilter { $RelPath -like 'approvals/*' } { $script:putBack = $true; $false }
        $r = SarSave $script:mig -Wave1 @{ keepSnapshotDays = 14 }
        $script:injected | Should -BeTrue -Because 'the other writer and the approver acted in the window'
        $script:putBack | Should -BeFalse -Because 'the approval is judged against the plan read after it, so it is never removed'
        @($r.ApprovalsInvalidated) | Should -Be @('wave-1')
        SarApprovalText $script:mig 'wave-2' | Should -Not -BeNullOrEmpty -Because 'the approval signs wave-2 of the plan as stored'
        SarSignsNow $script:mig 'wave-2' | Should -BeTrue
    }

    It 'an approver approves between the judgement and the delete: the delete leaves the new approval' {
        # wave-2's approval is out of date before the save (it signs a wave-2
        # nobody has now), so the removal judges it stale. In that moment the
        # approver approves wave-2 as stored.
        $file = Join-Path $script:mig 'approvals' 'wave-2.json'
        $doc = Get-Content $file -Raw | ConvertFrom-Json
        $doc.waveVersion = 'f' * 64
        [System.IO.File]::WriteAllText($file, ($doc | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
        Mock -ModuleName VmMigrationFactory Test-VmfWaveApprovalCurrent -ParameterFilter { $Wave -ceq 'wave-2' } {
            $signed = if ($Approval -and $Approval.PSObject.Properties['waveVersion']) { [string]$Approval.waveVersion } else { '' }
            $now = if ($WaveVersion) { $WaveVersion } else { SarVersion $PlanText $Wave }
            $current = [string]::Equals($signed, $now, [System.StringComparison]::Ordinal)
            if (-not $current -and -not $script:injected) {
                $script:injected = $true
                SarApprove $script:mig 'wave-2'
            }
            $current
        }
        $r = SarSave $script:mig -Wave1 @{ keepSnapshotDays = 14 }
        $script:injected | Should -BeTrue -Because 'the approver acted between the judgement and the delete'
        @($r.ApprovalsInvalidated) | Should -Not -Contain 'wave-2'
        SarApprovalText $script:mig 'wave-2' | Should -Not -BeNullOrEmpty
        SarSignsNow $script:mig 'wave-2' | Should -BeTrue
    }

    It 'an approval written between the judgement and the delete is judged again: out of date too, it goes' {
        $file = Join-Path $script:mig 'approvals' 'wave-2.json'
        $doc = Get-Content $file -Raw | ConvertFrom-Json
        $doc.waveVersion = 'f' * 64
        [System.IO.File]::WriteAllText($file, ($doc | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
        Mock -ModuleName VmMigrationFactory Test-VmfWaveApprovalCurrent -ParameterFilter { $Wave -ceq 'wave-2' } {
            $signed = if ($Approval -and $Approval.PSObject.Properties['waveVersion']) { [string]$Approval.waveVersion } else { '' }
            $now = if ($WaveVersion) { $WaveVersion } else { SarVersion $PlanText $Wave }
            if (-not $script:injected) {
                # Another out-of-date approval lands in the window.
                $script:injected = $true
                $other = Get-Content $file -Raw | ConvertFrom-Json
                $other.waveVersion = 'e' * 64
                [System.IO.File]::WriteAllText($file, ($other | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
            }
            [string]::Equals($signed, $now, [System.StringComparison]::Ordinal)
        }
        $r = SarSave $script:mig -Wave1 @{ keepSnapshotDays = 14 }
        $script:injected | Should -BeTrue
        @($r.ApprovalsInvalidated) | Should -Contain 'wave-2'
        SarApprovalText $script:mig 'wave-2' | Should -BeNullOrEmpty
    }

    It 'a wave the save changed, approved as saved before its approval is removed: the new approval stays' {
        # The save writes the plan; before it removes the approval of the wave
        # it changed, the approver approves that wave of the plan as saved.
        Mock -ModuleName VmMigrationFactory Write-VmfTextDocumentIfVersion {
            [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
            if (-not $script:injected) {
                $script:injected = $true
                SarApprove $script:mig 'wave-2'
            }
        }
        $r = SarSave $script:mig -Wave2 @{ keepSnapshotDays = 14 }
        $script:injected | Should -BeTrue
        @($r.ApprovalsInvalidated) | Should -Not -Contain 'wave-2' -Because 'no approval of wave-2 was removed: the one there signs the plan as saved'
        SarSignsNow $script:mig 'wave-2' | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig } {
            (Test-VmfWaveApproval -RunPath $m -PlanPath (Join-Path $m 'plan.json') -Wave 'wave-2').Pass
        } | Should -BeTrue
    }

    It 'without anybody in the window, the save still removes the approval of the wave it changed' {
        $r = SarSave $script:mig -Wave2 @{ keepSnapshotDays = 14 }
        @($r.ApprovalsInvalidated) | Should -Be @('wave-2')
        SarApprovalText $script:mig 'wave-2' | Should -BeNullOrEmpty
        SarSignsNow $script:mig 'wave-1' | Should -BeTrue
    }

    It 'the plan changes back after the judgement to the wave the approval signs: the approval is put back' {
        $signed = SarPlanText $script:mig
        SarOtherWriter $script:mig 21
        $before = SarApprovalText $script:mig 'wave-2'
        # The removal judges wave-2's approval against the changed plan, and
        # removes it; in that moment a writer puts wave-2 back as it was.
        Mock -ModuleName VmMigrationFactory Remove-VmfStoreItemIfVersion {
            Remove-Item -LiteralPath (Join-Path $RunPath $RelPath) -Force
            [System.IO.File]::WriteAllText((Join-Path $RunPath 'plan.json'), $signed, [System.Text.UTF8Encoding]::new($false))
            $true
        }
        $gone = InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig } {
            @(Remove-VmfStaleWaveApprovals -RunPath $m -PlanPath (Join-Path $m 'plan.json'))
        }
        @($gone) | Should -BeNullOrEmpty
        SarApprovalText $script:mig 'wave-2' | Should -BeExactly $before
    }

    It 'put back, then a third writer makes it out of date: it is judged again, and removed' {
        $signed = SarPlanText $script:mig
        SarOtherWriter $script:mig 21
        $script:removes = 0
        Mock -ModuleName VmMigrationFactory Remove-VmfStoreItemIfVersion {
            $script:removes++
            Remove-Item -LiteralPath (Join-Path $RunPath $RelPath) -Force
            # The first time, a writer puts wave-2 back as the approval signs it.
            if ($script:removes -eq 1) { [System.IO.File]::WriteAllText((Join-Path $RunPath 'plan.json'), $signed, [System.Text.UTF8Encoding]::new($false)) }
            $true
        }
        Mock -ModuleName VmMigrationFactory Write-VmfStoreTextExclusive -ParameterFilter { $RelPath -like 'approvals/*' } {
            [System.IO.File]::WriteAllText((Join-Path $RunPath $RelPath), $Content, [System.Text.UTF8Encoding]::new($false))
            # Just after the put-back, a third writer changes wave-2 again.
            SarOtherWriter $script:mig 30
            $true
        }
        $gone = InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig } {
            @(Remove-VmfStaleWaveApprovals -RunPath $m -PlanPath (Join-Path $m 'plan.json'))
        }
        $script:removes | Should -Be 2 -Because 'the approval put back is judged again against the plan the third writer saved'
        @($gone) | Should -Be @('wave-2')
        SarApprovalText $script:mig 'wave-2' | Should -BeNullOrEmpty
    }

    It 'an approval that cannot be read is kept, and the run history says so' {
        SarOtherWriter $script:mig 21
        Mock -ModuleName VmMigrationFactory Read-VmfStoreText -ParameterFilter { $RelPath -ceq 'approvals/wave-2.json' } { throw 'Store read failed: HTTP 503' }
        $gone = InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig } {
            @(Remove-VmfStaleWaveApprovals -RunPath $m -PlanPath (Join-Path $m 'plan.json'))
        }
        @($gone) | Should -BeNullOrEmpty
        SarApprovalText $script:mig 'wave-2' | Should -Not -BeNullOrEmpty
        @(SarEvents $script:mig) -match 'could not read the approval of wave wave-2' | Should -Not -BeNullOrEmpty
    }

    It 'an empty approval signs nothing: it is removed and named' {
        [System.IO.File]::WriteAllText((Join-Path $script:mig 'approvals' 'wave-2.json'), '', [System.Text.UTF8Encoding]::new($false))
        $gone = InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig } {
            @(Remove-VmfStaleWaveApprovals -RunPath $m -PlanPath (Join-Path $m 'plan.json'))
        }
        @($gone) | Should -Be @('wave-2')
        Test-Path (Join-Path $script:mig 'approvals' 'wave-2.json') | Should -BeFalse
        SarApprovalText $script:mig 'wave-1' | Should -Not -BeNullOrEmpty
    }

    It 'an approval that keeps changing is kept after five tries, and the run history says so' {
        SarOtherWriter $script:mig 21
        $script:removes = 0
        Mock -ModuleName VmMigrationFactory Remove-VmfStoreItemIfVersion { $script:removes++; $false }
        $gone = InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig } {
            @(Remove-VmfStaleWaveApprovals -RunPath $m -PlanPath (Join-Path $m 'plan.json'))
        }
        $script:removes | Should -Be 5
        @($gone) | Should -BeNullOrEmpty
        SarApprovalText $script:mig 'wave-2' | Should -Not -BeNullOrEmpty
        @(SarEvents $script:mig) -match 'approval of wave wave-2 changed while the product checked it' | Should -Not -BeNullOrEmpty
    }

    It 'a target change that is undone puts back the approval it removed, never over one given since' {
        $vm = (SarIds $script:mig 'wave-2')[0]
        # The plan write is refused (another writer, 409) after an approver
        # approved wave-2 again: the undo must not write the older approval over it.
        Mock -ModuleName VmMigrationFactory Write-VmfTextDocumentIfVersion {
            SarApproveNote $script:mig 'wave-2' 'second look'
            throw '409: Somebody changed the plan at the same time, so the product did not save this change.'
        }
        { Set-VmfMachineTarget -RunPath $script:mig -VmId $vm -Option 'v5' -ChangedBy 'operator@example.com' -Confirm:$false } | Should -Throw '409*'
        (SarApprovalText $script:mig 'wave-2' | ConvertFrom-Json).note | Should -Be 'second look'
    }

    It 'a target change takes the approval as it is when it removes it: one given in that moment is the one put back' {
        $vm = (SarIds $script:mig 'wave-2')[0]
        Mock -ModuleName VmMigrationFactory Read-VmfStoreText -ParameterFilter { $RelPath -ceq 'approvals/wave-2.json' } {
            $file = Join-Path $RunPath 'approvals' 'wave-2.json'
            $text = if (Test-Path $file) { [System.IO.File]::ReadAllText($file) } else { $null }
            if (-not $script:injected) {
                $script:injected = $true
                SarApproveNote $script:mig 'wave-2' 'second look'
            }
            $text
        }
        Mock -ModuleName VmMigrationFactory Write-VmfTextDocumentIfVersion { throw '409: Somebody changed the plan at the same time, so the product did not save this change.' }
        { Set-VmfMachineTarget -RunPath $script:mig -VmId $vm -Option 'v5' -ChangedBy 'operator@example.com' -Confirm:$false } | Should -Throw '409*'
        $script:injected | Should -BeTrue
        (SarApprovalText $script:mig 'wave-2' | ConvertFrom-Json).note | Should -Be 'second look'
    }

    It 'an approval that is out of date and stays so is removed and named' {
        SarOtherWriter $script:mig 21
        $gone = InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig } {
            @(Remove-VmfStaleWaveApprovals -RunPath $m -PlanPath (Join-Path $m 'plan.json'))
        }
        @($gone) | Should -Be @('wave-2')
        SarApprovalText $script:mig 'wave-2' | Should -BeNullOrEmpty
        SarApprovalText $script:mig 'wave-1' | Should -Not -BeNullOrEmpty
    }
}

Describe 'STALE-APPROVAL-RACE-1: Remove-VmfStoreItemIfVersion removes only the text that was judged' {
    BeforeEach {
        $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sar-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:dir 'approvals') -Force | Out-Null
        $script:file = Join-Path $script:dir 'approvals' 'w1.json'
        [System.IO.File]::WriteAllText($script:file, '{"a":1}', [System.Text.UTF8Encoding]::new($false))
        $script:v1 = InModuleScope VmMigrationFactory { Get-VmfDocumentVersion -Text '{"a":1}' }
    }
    AfterEach { Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'removes the document when it still holds the version judged' {
        InModuleScope VmMigrationFactory -Parameters @{ d = $script:dir; v = $script:v1 } {
            Remove-VmfStoreItemIfVersion -RunPath $d -RelPath 'approvals/w1.json' -ExpectedVersion $v
        } | Should -BeTrue
        Test-Path $script:file | Should -BeFalse
        @(Get-ChildItem (Join-Path $script:dir 'approvals')).Count | Should -Be 0 -Because 'nothing is left beside it'
    }

    It 'keeps a document somebody wrote after the judgement, as it is' {
        [System.IO.File]::WriteAllText($script:file, '{"a":"theirs"}', [System.Text.UTF8Encoding]::new($false))
        InModuleScope VmMigrationFactory -Parameters @{ d = $script:dir; v = $script:v1 } {
            Remove-VmfStoreItemIfVersion -RunPath $d -RelPath 'approvals/w1.json' -ExpectedVersion $v
        } | Should -BeFalse
        Get-Content $script:file -Raw | Should -Be '{"a":"theirs"}'
        @(Get-ChildItem (Join-Path $script:dir 'approvals')).Count | Should -Be 1
    }

    It 'a document written while the judged text is aside stays, and the judged text is removed' {
        Mock -ModuleName VmMigrationFactory Read-VmfFileTextShared -ParameterFilter { $Path -like '*.removing-*' } {
            [System.IO.File]::WriteAllText($script:file, '{"a":"new"}', [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::ReadAllText($Path)
        }
        InModuleScope VmMigrationFactory -Parameters @{ d = $script:dir; v = $script:v1 } {
            Remove-VmfStoreItemIfVersion -RunPath $d -RelPath 'approvals/w1.json' -ExpectedVersion $v
        } | Should -BeTrue
        Get-Content $script:file -Raw | Should -Be '{"a":"new"}'
        @(Get-ChildItem (Join-Path $script:dir 'approvals')).Count | Should -Be 1
    }

    It 'a document written while another text is aside: the newest stays, and nothing is left aside' {
        [System.IO.File]::WriteAllText($script:file, '{"a":"theirs"}', [System.Text.UTF8Encoding]::new($false))
        Mock -ModuleName VmMigrationFactory Read-VmfFileTextShared -ParameterFilter { $Path -like '*.removing-*' } {
            [System.IO.File]::WriteAllText($script:file, '{"a":"newest"}', [System.Text.UTF8Encoding]::new($false))
            [System.IO.File]::ReadAllText($Path)
        }
        InModuleScope VmMigrationFactory -Parameters @{ d = $script:dir; v = $script:v1 } {
            Remove-VmfStoreItemIfVersion -RunPath $d -RelPath 'approvals/w1.json' -ExpectedVersion $v
        } | Should -BeFalse
        Get-Content $script:file -Raw | Should -Be '{"a":"newest"}'
        @(Get-ChildItem (Join-Path $script:dir 'approvals')).Count | Should -Be 1
    }

    It 'a text left aside by a remover that stopped, more than a minute ago, is removed; a newer one is not' {
        $old = "$script:file.removing-$([DateTime]::UtcNow.AddMinutes(-5).Ticks)-abc"
        $new = "$script:file.removing-$([DateTime]::UtcNow.Ticks)-def"
        foreach ($left in $old, $new) { [System.IO.File]::WriteAllText($left, '{}', [System.Text.UTF8Encoding]::new($false)) }
        InModuleScope VmMigrationFactory -Parameters @{ d = $script:dir; v = $script:v1 } {
            Remove-VmfStoreItemIfVersion -RunPath $d -RelPath 'approvals/w1.json' -ExpectedVersion $v
        } | Should -BeTrue
        Test-Path -LiteralPath $old | Should -BeFalse
        Test-Path -LiteralPath $new | Should -BeTrue
    }

    It 'a document that is gone is not removed by this call' {
        Remove-Item -LiteralPath $script:file
        InModuleScope VmMigrationFactory -Parameters @{ d = $script:dir; v = $script:v1 } {
            Remove-VmfStoreItemIfVersion -RunPath $d -RelPath 'approvals/w1.json' -ExpectedVersion $v
        } | Should -BeFalse
    }

    Context 'on blob storage' {
        BeforeEach {
            $script:calls = [System.Collections.Generic.List[object]]::new()
            $script:stored = '{"a":1}'
            $script:getCode = 200
            $script:deleteCode = 202
            Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
                $script:calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Headers = $Headers })
                if ($Method -eq 'GET') {
                    return [pscustomobject]@{ StatusCode = $script:getCode; Content = $script:stored; Headers = @{ ETag = @('"0x8D1"') } }
                }
                [pscustomobject]@{ StatusCode = $script:deleteCode; Content = '' }
            }
        }

        It 'the delete carries If-Match with the ETag of the text it judged' {
            InModuleScope VmMigrationFactory -Parameters @{ v = $script:v1 } {
                Remove-VmfStoreItemIfVersion -RunPath 'azblob://acct/cont/run-1' -RelPath 'approvals/w1.json' -ExpectedVersion $v
            } | Should -BeTrue
            $del = @($script:calls | Where-Object Method -eq 'DELETE')
            $del.Count | Should -Be 1
            $del[0].Headers['If-Match'] | Should -Be '"0x8D1"'
            $del[0].Uri | Should -Match 'acct\.blob\.core\.windows\.net/cont/run-1/approvals/w1\.json$'
        }

        It 'a version that differs is kept, and no delete is sent' {
            $script:stored = '{"a":"theirs"}'
            InModuleScope VmMigrationFactory -Parameters @{ v = $script:v1 } {
                Remove-VmfStoreItemIfVersion -RunPath 'azblob://acct/cont/run-1' -RelPath 'approvals/w1.json' -ExpectedVersion $v
            } | Should -BeFalse
            @($script:calls | Where-Object Method -eq 'DELETE').Count | Should -Be 0
        }

        It 'a write between the read and the delete fails the If-Match: kept' {
            $script:deleteCode = 412
            InModuleScope VmMigrationFactory -Parameters @{ v = $script:v1 } {
                Remove-VmfStoreItemIfVersion -RunPath 'azblob://acct/cont/run-1' -RelPath 'approvals/w1.json' -ExpectedVersion $v
            } | Should -BeFalse
        }

        It 'a document that is gone sends no delete' {
            $script:getCode = 404
            InModuleScope VmMigrationFactory -Parameters @{ v = $script:v1 } {
                Remove-VmfStoreItemIfVersion -RunPath 'azblob://acct/cont/run-1' -RelPath 'approvals/w1.json' -ExpectedVersion $v
            } | Should -BeFalse
            @($script:calls | Where-Object Method -eq 'DELETE').Count | Should -Be 0
        }
    }
}
