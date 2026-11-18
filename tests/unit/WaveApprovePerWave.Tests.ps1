#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# WAVE-APPROVE-1: each wave's approval signs only its own wave.
#
# Decided 2026-10-05 (OWNER-QUESTIONS-1 row 6, option 2): each wave's
# approval signs only its own wave's machines and settings, so a change to one
# wave asks again for that wave only. "Sign off all" stays, as one approval per
# wave. Found by WAVE-SAVE-FALSE-1: an approval signed the whole plan text, so a
# change to wave-2 removed wave-1's approval as well.
#
# Driven through the real flow: a scan, the targets, New-VmfPlan with waves by a
# tag, the real approval writers, the real plan writers (Set-VmfWavePlan,
# Set-VmfMachineTarget's sibling the decision carry), the engine's own start
# gates, Start-VmfWave up to its worker launch, then real worker processes with
# a fake engine. No test here runs the watch loop of Start-VmfWave beside real
# workers: on the file store that loop can meet a worker creating a lease (see
# the WAVE-APPROVE-1 work item, Follow-ups).

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:workerScript = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Workers' 'worker.ps1'

    function Global:WapSku([string]$Name) {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V2' }) }
    }
    function Global:WapId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
    function Global:WapVm([string]$Name, [string]$Environment) {
        [ordered]@{
            vmId = (WapId $Name); name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @()
            classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; osVersion = '22_04-lts-gen2'
            sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = 'SCSI'
            dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; iacManaged = $false; hibernationEnabled = $false; availabilitySetId = ''
            identityType = 'None'; tags = @{ environment = $Environment }; blockers = @(); prepNeeded = @()
        }
    }
    function Global:WapPlanPath($mig) { Join-Path $mig 'plan.json' }
    function Global:WapPlanText($mig) { [System.IO.File]::ReadAllText((WapPlanPath $mig)) }
    function Global:WapPlan($mig) { (WapPlanText $mig) | ConvertFrom-Json -Depth 30 }
    $script:who = @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }

    # Scan, review, targets, plan by a tag: wave-1 holds app-01 and app-02
    # (dev), wave-2 holds web-01 and web-02 (prod). Every wave's settings
    # accepted and the run acknowledged, so the approval is the gate under test.
    function Global:WapPlanned {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wap-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $vms = @((WapVm 'app-01' 'dev'), (WapVm 'app-02' 'dev'), (WapVm 'web-01' 'prod'), (WapVm 'web-02' 'prod'))
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
        Confirm-VmfRunAcknowledgement -RunPath $mig -AcknowledgedBy 'operator@example.com' -Confirm:$false | Out-Null
        foreach ($w in 'wave-1', 'wave-2') {
            Confirm-VmfWaveOptions -RunPath $mig -PlanPath (WapPlanPath $mig) -Wave $w -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        }
        @{ Scan = $rp; Mig = $mig }
    }
    function Global:WapApprove($mig, [string]$Wave) {
        Approve-VmfWave -RunPath $mig -PlanPath (WapPlanPath $mig) -Wave $Wave -Note 'read and approved' `
            -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
    }
    function Global:WapGate($mig, [string]$Wave) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig; w = $Wave } {
            Test-VmfWaveApproval -RunPath $m -PlanPath (Join-Path $m 'plan.json') -Wave $w
        }
    }
    function Global:WapApprovalDoc($mig, [string]$Wave) {
        $file = Join-Path $mig 'approvals' "$Wave.json"
        if (Test-Path $file) { Get-Content $file -Raw | ConvertFrom-Json -Depth 10 } else { $null }
    }
    function Global:WapIds($mig, [string]$Wave) { @((WapPlan $mig).entries | Where-Object { $_.wave -eq $Wave } | ForEach-Object { [string]$_.vmId }) }
    # The command line's layout: both waves, each with its machines, and the
    # settings given for one of them. Both waves are named so the order stays.
    function Global:WapSave($mig, [hashtable]$Wave1 = @{}, [hashtable]$Wave2 = @{}, [string[]]$Ids1, [string[]]$Ids2) {
        $one = [ordered]@{ name = 'wave-1'; vmIds = @($(if ($PSBoundParameters.ContainsKey('Ids1')) { $Ids1 } else { WapIds $mig 'wave-1' })) }
        foreach ($k in $Wave1.Keys) { $one[$k] = $Wave1[$k] }
        $two = [ordered]@{ name = 'wave-2'; vmIds = @($(if ($PSBoundParameters.ContainsKey('Ids2')) { $Ids2 } else { WapIds $mig 'wave-2' })) }
        foreach ($k in $Wave2.Keys) { $two[$k] = $Wave2[$k] }
        Set-VmfWavePlan -RunPath $mig -PlanPath (WapPlanPath $mig) -Layout @{ waves = @($one, $two) } -ChangedBy 'operator@example.com' -Confirm:$false
    }
    function Global:WapVersion([string]$Text, [string]$Wave) {
        InModuleScope VmMigrationFactory -Parameters @{ t = $Text; w = $Wave } { Get-VmfWaveVersion -PlanText $t -Wave $w }
    }
    function Global:WapFakeEngine($mig) {
        $fake = Join-Path $mig 'fake-engine.ps1'
        @'
param($EntryJson, $RunPath, $RunId)
$entry = $EntryJson | ConvertFrom-Json -Depth 24
& (Get-Module VmMigrationFactory) { param($id, $rp, $rid)
    New-VmfStateDoc -RunPath $rp -RunId $rid -VmId $id | Out-Null
    Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok | Out-Null
} $entry.vmId $RunPath $RunId
'@ | Set-Content $fake
        $fake
    }
    function Global:WapState($mig, [string]$VmId) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig; id = $VmId } {
            $d = Read-VmfStateDoc -RunPath $m -VmId $id -ErrorAction SilentlyContinue
            if ($d) { [string]$d.state } else { '' }
        }
    }
}
AfterAll {
    foreach ($fn in 'WapSku', 'WapId', 'WapVm', 'WapPlanPath', 'WapPlanText', 'WapPlan', 'WapPlanned', 'WapApprove', 'WapGate',
                    'WapApprovalDoc', 'WapIds', 'WapSave', 'WapVersion', 'WapFakeEngine', 'WapState') {
        Remove-Item "function:\$fn" -ErrorAction SilentlyContinue
    }
}

Describe 'WAVE-APPROVE-1: the version a wave approval signs (Get-VmfWaveVersion)' {
    BeforeAll {
        # Two waves, a machine that does not move, a decision with a time, and
        # a second machine of wave-1 whose wave is written in capitals.
        $script:base = [ordered]@{
            schemaVersion = 5; generatedUtc = '2026-10-01T00:00:00Z'; assessmentRunId = 'scan-1'
            waveOrder = @('wave-1', 'wave-2'); waveSummary = @(); pathSummary = @()
            entries = @(
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = 'vm-a'; wave = 'wave-1'; path = 'A'; target = [ordered]@{ size = 'Standard_D2s_v6' }
                    policy = [ordered]@{ requireApproval = $true; throttle = 3 }
                    decisions = @([ordered]@{ setting = 'onDriverBelowFloor'; by = 'approver@example.com'; utc = '2026-10-05T09:12:00.1230000Z' }) }
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = 'vm-b'; wave = 'WAVE-1'; path = 'B'; target = [ordered]@{ size = 'Standard_D4s_v6' }; policy = [ordered]@{ requireApproval = $true } }
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = 'vm-m'; wave = 'wave-1'; path = 'MANUAL'; target = [ordered]@{ size = $null }; policy = [ordered]@{ requireApproval = $true } }
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = 'vm-c'; wave = 'wave-2'; path = 'A'; target = [ordered]@{ size = 'Standard_D2s_v6' }; policy = [ordered]@{ requireApproval = $true } })
        }
        $script:text = $script:base | ConvertTo-Json -Depth 12
        $script:edit = {
            param([scriptblock]$Change)
            $p = $script:text | ConvertFrom-Json -Depth 24
            & $Change $p
            $p | ConvertTo-Json -Depth 24
        }
    }

    It 'is the same for the same text, and is lower-case hex' {
        $v = WapVersion $script:text 'wave-1'
        $v | Should -MatchExactly '^[0-9a-f]{64}$'
        WapVersion $script:text 'wave-1' | Should -BeExactly $v
        WapVersion $script:text 'wave-2' | Should -Not -Be $v
    }

    It 'a change to a machine of wave-2 changes wave-2 only' {
        $after = & $script:edit { param($p) ($p.entries | Where-Object vmId -eq 'vm-c').target.size = 'Standard_D4s_v6' }
        WapVersion $after 'wave-1' | Should -BeExactly (WapVersion $script:text 'wave-1')
        WapVersion $after 'wave-2' | Should -Not -Be (WapVersion $script:text 'wave-2')
    }

    It 'a setting, a path or a decision of one machine is part of its wave' {
        foreach ($change in @(
                { param($p) ($p.entries | Where-Object vmId -eq 'vm-a').policy.throttle = 5 },
                { param($p) ($p.entries | Where-Object vmId -eq 'vm-a').path = 'B' },
                { param($p) ($p.entries | Where-Object vmId -eq 'vm-a').decisions[0].setting = 'onDDataFound' })) {
            $after = & $script:edit $change
            WapVersion $after 'wave-1' | Should -Not -Be (WapVersion $script:text 'wave-1') -Because "$change"
            WapVersion $after 'wave-2' | Should -BeExactly (WapVersion $script:text 'wave-2')
        }
    }

    It 'a machine that does not move is part of its wave too - a change to make it move is a change to the wave' {
        $after = & $script:edit { param($p) ($p.entries | Where-Object vmId -eq 'vm-m').path = 'A' }
        WapVersion $after 'wave-1' | Should -Not -Be (WapVersion $script:text 'wave-1')
    }

    It 'the wave is chosen the way a worker chooses it: a wave name in other letters is inside it' {
        # Get-VmfNextWaveVm takes `wave -eq` - which ignores case - so vm-b is a
        # machine wave-1's workers would run. It must be inside what is signed.
        $after = & $script:edit { param($p) ($p.entries | Where-Object vmId -eq 'vm-b').target.size = 'Standard_D8s_v6' }
        WapVersion $after 'wave-1' | Should -Not -Be (WapVersion $script:text 'wave-1')
    }

    It 'a machine moved from wave-1 to wave-2 changes both' {
        $after = & $script:edit { param($p) ($p.entries | Where-Object vmId -eq 'vm-a').wave = 'wave-2' }
        WapVersion $after 'wave-1' | Should -Not -Be (WapVersion $script:text 'wave-1')
        WapVersion $after 'wave-2' | Should -Not -Be (WapVersion $script:text 'wave-2')
    }

    It 'a plan-wide field - the format version or the assessment - changes every wave' {
        foreach ($change in @({ param($p) $p.schemaVersion = 6 }, { param($p) $p.assessmentRunId = 'scan-2' })) {
            $after = & $script:edit $change
            foreach ($w in 'wave-1', 'wave-2') {
                WapVersion $after $w | Should -Not -Be (WapVersion $script:text $w) -Because "$change changes what every wave is"
            }
        }
    }

    It 'the order of the waves, the summaries and the time of planning change no wave' {
        $after = & $script:edit { param($p)
            $p.waveOrder = @('wave-2', 'wave-1'); $p.waveSummary = @([ordered]@{ wave = 'wave-1'; count = 9 })
            $p.pathSummary = @([ordered]@{ path = 'A'; count = 9 }); $p.generatedUtc = '2026-10-09T00:00:00Z' }
        foreach ($w in 'wave-1', 'wave-2') { WapVersion $after $w | Should -BeExactly (WapVersion $script:text $w) }
    }

    It 'the order of the entries in the file changes no wave' {
        $after = & $script:edit { param($p) $p.entries = @($p.entries[3], $p.entries[2], $p.entries[1], $p.entries[0]) }
        foreach ($w in 'wave-1', 'wave-2') { WapVersion $after $w | Should -BeExactly (WapVersion $script:text $w) }
    }

    It 'a writer that parses and writes the whole plan again changes no wave, dates included' {
        # Every plan writer does this to change one wave. Measured: the first
        # rewrite turns '...00.1230000Z' into '...00.123Z', so a hash of the
        # raw text of the other wave would ask again for a wave nobody changed.
        $rewritten = ($script:text | ConvertFrom-Json -Depth 24) | ConvertTo-Json -Depth 24
        $rewritten | Should -Not -BeExactly $script:text -Because 'the rewrite really changed the text'
        $rewritten | Should -Match '09:12:00\.123Z'
        foreach ($w in 'wave-1', 'wave-2') { WapVersion $rewritten $w | Should -BeExactly (WapVersion $script:text $w) }
    }

    It 'GOLDEN: the canonical form is fixed - a change to it changes this exact hash' {
        # Dates with Z, with an offset and with no zone; a fraction; a whole
        # number written as a double; non-ASCII text, a quote, a backslash and
        # a control character; arrays three deep; null beside a missing field;
        # keys out of order. The service writes an approval and the engine
        # checks it on two PowerShell installs, so any change to the form - by
        # code or by a runtime - must fail here, not in a customer's wave.
        $fixture = @'
{"schemaVersion":5,"assessmentRunId":"golden","entries":[
 {"vmId":"vm-1","wave":"g","seen":"2026-10-05T09:12:00.1230000Z","near":"2026-10-05T11:12:00+02:00","plain":"2026-10-05T09:12:00",
  "ratio":0.25,"whole":3.0,"name":"café \"q\" \\ \u0007 東","deep":[[[1,[2]],["x"]]],"gone":null},
 {"vmId":"vm-0","wave":"G","policy":{"b":true,"a":false}}]}
'@
        $canon = InModuleScope VmMigrationFactory -Parameters @{ t = $fixture } {
            $doc = [System.Text.Json.JsonDocument]::Parse($t)
            try { ConvertTo-VmfCanonicalJson -Element $doc.RootElement.GetProperty('entries')[0] } finally { $doc.Dispose() }
        }
        $expected = '{"deep":[[[1,[2]],["x"]]],"gone":null,"name":"caf' + [char]0xE9 + ' \"q\" \\ \u0007 ' + [char]0x6771 + '",' +
            '"near":"2026-10-05T09:12:00.0000000Z","plain":"2026-10-05T09:12:00.0000000","ratio":0.25,' +
            '"seen":"2026-10-05T09:12:00.1230000Z","vmId":"vm-1","wave":"g","whole":3}'
        $canon | Should -BeExactly $expected
        # vm-0's wave reads G: inside wave g, as a worker of g would take it.
        WapVersion $fixture 'g' | Should -BeExactly '5f01d799af672173ab845ec3fe80cb66f76eeac1f6f0a2ab2d132d2220591fa6'
    }

    It 'a value nested three levels deep is part of the version' {
        $a = '{"entries":[{"vmId":"v","wave":"w","x":{"y":{"z":{"q":1}}}}]}'
        $b = '{"entries":[{"vmId":"v","wave":"w","x":{"y":{"z":{"q":2}}}}]}'
        WapVersion $a 'w' | Should -Not -Be (WapVersion $b 'w')
    }

    It 'null and missing are different; 1, 1.0 and 1.00 are one value, as a rewrite makes them' {
        WapVersion '{"entries":[{"vmId":"v","wave":"w","k":null}]}' 'w' | Should -Not -Be (WapVersion '{"entries":[{"vmId":"v","wave":"w"}]}' 'w')
        WapVersion '{"entries":[{"vmId":"v","wave":"w","k":1}]}' 'w' | Should -BeExactly (WapVersion '{"entries":[{"vmId":"v","wave":"w","k":1.00}]}' 'w')
    }

    It 'two waves whose names differ only in case are two versions' {
        $two = '{"entries":[{"vmId":"a","wave":"w1"},{"vmId":"b","wave":"W1"}]}'
        $v = InModuleScope VmMigrationFactory -Parameters @{ t = $two } { Get-VmfWaveVersions -PlanText $t -Wave @('w1', 'W1') }
        $v.Count | Should -Be 2
        $v['w1'] | Should -Not -Be $v['W1']
    }

    It 'a time is read as its instant, so the computer it is read on does not matter' {
        $utc = & $script:edit { param($p) ($p.entries | Where-Object vmId -eq 'vm-c') | Add-Member -NotePropertyName seen -NotePropertyValue '2026-10-05T09:12:00Z' }
        $offset = & $script:edit { param($p) ($p.entries | Where-Object vmId -eq 'vm-c') | Add-Member -NotePropertyName seen -NotePropertyValue '2026-10-05T11:12:00+02:00' }
        $later = & $script:edit { param($p) ($p.entries | Where-Object vmId -eq 'vm-c') | Add-Member -NotePropertyName seen -NotePropertyValue '2026-10-05T11:12:00Z' }
        WapVersion $offset 'wave-2' | Should -BeExactly (WapVersion $utc 'wave-2')
        WapVersion $later 'wave-2' | Should -Not -Be (WapVersion $utc 'wave-2')
    }

    It 'an approval copied to another wave signs nothing there: the name is part of it' {
        $two = & $script:edit { param($p) foreach ($e in $p.entries) { if ($e.vmId -eq 'vm-c') { $e.wave = 'wave-3' } } }
        WapVersion $two 'wave-3' | Should -Not -Be (WapVersion $script:text 'wave-2')
        # Every entry names its wave, so two waves with machines differ anyway.
        # Two waves with none differ only by the name - the case the name is for
        # (found by the mutation that took the name out: this test passed).
        WapVersion $script:text 'ghost-1' | Should -Not -Be (WapVersion $script:text 'ghost-2')
    }
}

Describe 'WAVE-APPROVE-1: a change to one wave asks again for that wave only' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((WapSku 'Standard_D2ds_v6'), (WapSku 'Standard_D2s_v6')) }
        # ENGINE-SUB-1's reach of the subscription is not under test here.
        Mock -ModuleName VmMigrationFactory Test-VmfWaveSubscriptions { [pscustomobject]@{ Pass = $true } }
        $script:run = WapPlanned
        $script:mig = $script:run.Mig
        WapApprove $script:mig 'wave-1'
        WapApprove $script:mig 'wave-2'
    }
    AfterEach {
        Remove-Item Env:\VMF_TEST_ENGINE -ErrorAction SilentlyContinue
        # Start-VmfWave makes a folder for its workers' output before the launch.
        if ($script:run.Mig) {
            Remove-Item (Join-Path ([System.IO.Path]::GetTempPath()) "vmf-workers-$(Split-Path $script:run.Mig -Leaf)") -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'an approval is v4 (REBUILD-REMOVE-ACCEPT-1 stopped writing identityLoss; v2 added the wave version) and signs its own wave of the plan it was shown' {
        $doc = WapApprovalDoc $script:mig 'wave-1'
        $doc.schemaVersion | Should -Be 5
        $doc.waveVersion | Should -BeExactly (WapVersion (WapPlanText $script:mig) 'wave-1')
        $doc.planHash | Should -MatchExactly '^[0-9a-f]{64}$'
        (WapGate $script:mig 'wave-1').Pass | Should -BeTrue
        (WapGate $script:mig 'wave-2').Pass | Should -BeTrue
    }

    It 'a setting changed on wave-2: wave-2 asks again, wave-1 keeps its approval' {
        $r = WapSave $script:mig -Wave2 @{ keepSnapshotDays = 14 }
        @($r.ApprovalsInvalidated) | Should -Be @('wave-2')
        WapApprovalDoc $script:mig 'wave-2' | Should -BeNullOrEmpty
        $gate = WapGate $script:mig 'wave-2'
        $gate.Pass | Should -BeFalse
        $gate.Code | Should -Be 'notApproved'
        WapApprovalDoc $script:mig 'wave-1' | Should -Not -BeNullOrEmpty
        (WapGate $script:mig 'wave-1').Pass | Should -BeTrue
        # And the activity says nothing about wave-1's approval.
        $line = @(Get-Content (Join-Path $script:mig 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.step -eq 'plan' }) | Select-Object -Last 1
        $line.detail | Should -Match 'approval cleared for wave-2'
        $line.detail | Should -Not -Match 'wave-1 signed the plan|approval of wave wave-1'
    }

    It 'a target changed on a wave-2 machine (an edit by hand, then the writers'' removal): wave-1 keeps its approval' {
        $plan = WapPlan $script:mig
        ($plan.entries | Where-Object { $_.wave -eq 'wave-2' } | Select-Object -First 1).target.size = 'Standard_D4s_v6'
        $text = $plan | ConvertTo-Json -Depth 24
        [System.IO.File]::WriteAllText((WapPlanPath $script:mig), $text, [System.Text.UTF8Encoding]::new($false))
        $gone = InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig; t = $text } { Remove-VmfStaleWaveApprovals -RunPath $m -PlanPath (Join-Path $m 'plan.json') }
        @($gone) | Should -Be @('wave-2')
        (WapGate $script:mig 'wave-1').Pass | Should -BeTrue
        (WapGate $script:mig 'wave-2').Pass | Should -BeFalse
    }

    It 'a machine moved from wave-1 to wave-2 asks again for both' {
        $one = WapIds $script:mig 'wave-1'
        $two = WapIds $script:mig 'wave-2'
        $r = WapSave $script:mig -Ids1 @($one[0]) -Ids2 @($two + $one[1])
        $r.MovedCount | Should -Be 1
        @($r.ApprovalsInvalidated | Sort-Object) | Should -Be @('wave-1', 'wave-2')
        (WapGate $script:mig 'wave-1').Pass | Should -BeFalse
        (WapGate $script:mig 'wave-2').Pass | Should -BeFalse
    }

    It 'a plan-wide field changed asks again for every wave' {
        $plan = WapPlan $script:mig
        $plan.assessmentRunId = 'another-scan'
        $text = $plan | ConvertTo-Json -Depth 24
        [System.IO.File]::WriteAllText((WapPlanPath $script:mig), $text, [System.Text.UTF8Encoding]::new($false))
        $gone = InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig; t = $text } { Remove-VmfStaleWaveApprovals -RunPath $m -PlanPath (Join-Path $m 'plan.json') }
        @($gone | Sort-Object) | Should -Be @('wave-1', 'wave-2')
    }

    It 'only the order of the waves changed: no wave asks again' {
        $r = Set-VmfWavePlan -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Confirm:$false -ChangedBy 'operator@example.com' `
            -Layout @{ waves = @([ordered]@{ name = 'wave-2'; vmIds = @(WapIds $script:mig 'wave-2') }, [ordered]@{ name = 'wave-1'; vmIds = @(WapIds $script:mig 'wave-1') }) }
        $r.Unchanged | Should -BeFalse -Because 'the order is a real change, and is written'
        @((WapPlan $script:mig).waveOrder) | Should -Be @('wave-2', 'wave-1')
        @($r.ApprovalsInvalidated) | Should -BeNullOrEmpty
        (WapGate $script:mig 'wave-1').Pass | Should -BeTrue
        (WapGate $script:mig 'wave-2').Pass | Should -BeTrue
    }

    It 'after a change to wave-2, wave-1 passes every start gate and STARTS, and its machines move' {
        WapSave $script:mig -Wave2 @{ keepSnapshotDays = 14 } | Out-Null
        # The change cleared wave-2's accepted settings too; accepted again, so
        # its approval is the gate that refuses it below.
        Confirm-VmfWaveOptions -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Wave 'wave-2' -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig } {
            $plan = Read-VmfPlanDocument -RunPath $m
            Get-VmfWaveStartGate -RunPath $m -PlanPath (Join-Path $m 'plan.json') -Plan $plan -Wave 'wave-1' | Should -BeNullOrEmpty
            (Get-VmfWaveStartGate -RunPath $m -PlanPath (Join-Path $m 'plan.json') -Plan $plan -Wave 'wave-2').Code | Should -Be 'notApproved'
        }
        # FILE-BACKEND-RACE-1 put this back as it was before the 2026-10-10
        # follow-up: Start-VmfWave runs every start gate, launches its real
        # workers, and its watch loop (watchdog, breaker, run status, claim
        # release, final tally) reads their lease files while they create,
        # renew and release them on the file store. The launch is recorded and
        # then made for real, so the arguments are checked too.
        $script:wapSpawned = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName VmMigrationFactory Start-Process {
            $script:wapSpawned.Add(@($ArgumentList))
            # A Pester mock gets the parameters as variables, not in
            # $PSBoundParameters, so the real launch is rebuilt by name.
            $real = @{ FilePath = $FilePath; ArgumentList = $ArgumentList; PassThru = $true
                RedirectStandardOutput = $RedirectStandardOutput; RedirectStandardError = $RedirectStandardError }
            if ($WindowStyle) { $real.WindowStyle = $WindowStyle }
            Microsoft.PowerShell.Management\Start-Process @real
        }
        $env:VMF_TEST_ENGINE = WapFakeEngine $script:mig
        Start-VmfWave -PlanPath (WapPlanPath $script:mig) -Wave 'wave-1' -RunPath $script:mig -SkipCapacityGate -ThrottleLimit 1 | Out-Null
        $script:wapSpawned.Count | Should -Be 1
        $workerArgs = @($script:wapSpawned[0])
        $workerArgs[[array]::IndexOf($workerArgs, '-Wave') + 1] | Should -BeExactly 'wave-1'
        $workerArgs[[array]::IndexOf($workerArgs, '-WaveVersion') + 1] | Should -BeExactly (WapVersion (WapPlanText $script:mig) 'wave-1') `
            -Because 'the workers are handed the version of wave-1 as it is now, after the change to wave-2'
        foreach ($id in WapIds $script:mig 'wave-1') { WapState $script:mig $id | Should -Be 'MIGRATED' }
        foreach ($id in WapIds $script:mig 'wave-2') { WapState $script:mig $id | Should -Be '' -Because 'wave-2 was not started' }
        { Start-VmfWave -PlanPath (WapPlanPath $script:mig) -Wave 'wave-2' -RunPath $script:mig -SkipCapacityGate -ThrottleLimit 1 } |
            Should -Throw 'Nobody approved wave wave-2*'
        $script:wapSpawned.Count | Should -Be 1 -Because 'wave-2 is refused before any worker is launched'
    }

    It 'WAVE-APPROVE-1 (review 4): a start given the wave version the timer judged refuses when its own read differs, and starts when it is the same' {
        # The timer judges the next wave on one read and the engine starts on
        # another. A change to the wave in between - here approved again, so
        # every gate passes on the new text - is not what the timer judged.
        $judged = WapVersion (WapPlanText $script:mig) 'wave-1'
        WapSave $script:mig -Wave1 @{ keepSnapshotDays = 21 } | Out-Null
        Confirm-VmfWaveOptions -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Wave 'wave-1' -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        WapApprove $script:mig 'wave-1'
        $env:VMF_TEST_ENGINE = WapFakeEngine $script:mig
        { Start-VmfWave -PlanPath (WapPlanPath $script:mig) -Wave 'wave-1' -RunPath $script:mig -SkipCapacityGate -ThrottleLimit 1 -WaveVersion $judged } |
            Should -Throw 'Wave wave-1 changed after the service checked it for this start, so it did not start. The service checks the wave again at its next check.'
        foreach ($id in WapIds $script:mig 'wave-1') { WapState $script:mig $id | Should -Be '' -Because 'no machine was started' }
        @(Get-ChildItem (Join-Path $script:mig 'leases') -ErrorAction SilentlyContinue).Count | Should -Be 0 -Because 'no worker was started'
        # The same version as its own read: it goes on to the start gates. The
        # first gate is stopped there, so no worker is started: the launch and
        # the worker's run are proven above ('wave-1 ... STARTS'), and a watch
        # loop on the file store can meet a worker writing a lease.
        Mock -ModuleName VmMigrationFactory Test-VmfRunAcknowledged { throw 'reached the start gates' }
        { Start-VmfWave -PlanPath (WapPlanPath $script:mig) -Wave 'wave-1' -RunPath $script:mig -SkipCapacityGate -ThrottleLimit 1 `
            -WaveVersion (WapVersion (WapPlanText $script:mig) 'wave-1') } | Should -Throw 'reached the start gates'
    }

    It 'WAVE-APPROVE-1 (review 4): the wave version reaches the engine - the job''s setting, then Start-VmfWave' {
        $entry = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1')
        $entry | Should -Match "if \(\`$env:VMF_WAVE_VERSION\) \{ \`$waveParams\.WaveVersion = \[string\]\`$env:VMF_WAVE_VERSION \}"
        $core = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $core | Should -Match "if \(\`$Operation -eq 'wave' -and \`$WaveVersion\) \{ \`$overrides \+= @\{ name = 'VMF_WAVE_VERSION'; value = \`$WaveVersion \} \}"
        $continue = [regex]::Match($core, '(?ms)^function Invoke-VmfFacadeContinuePlan \{.*?^\}').Value
        $continue | Should -Match '-WaveVersion \(\[string\]\$d\.WaveVersion\)'
    }

    It 'Start-VmfWave hands every worker the version of its WAVE, from the one text its checks judged' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1')
        $code | Should -Match '\$read = Read-VmfPlanFileVersioned -Path \$PlanPath'
        $code | Should -Match '\$checkedWaveVersion = Get-VmfWaveVersion -PlanText \$read\.Text -Wave \$Wave'
        $code | Should -Match "'-WaveVersion', \`$checkedWaveVersion"
        $code | Should -Match 'Test-VmfWaveApproval -RunPath \$RunPath -PlanPath \$PlanPath -Wave \$Wave -PlanText \$read\.Text'
        $code | Should -Not -Match "'-PlanVersion'"
    }

    It 'a worker: an edit to ANOTHER wave between the checks and the worker is not a reason to take no machine' {
        $checked = WapVersion (WapPlanText $script:mig) 'wave-1'
        WapSave $script:mig -Wave2 @{ keepSnapshotDays = 14 } | Out-Null
        $env:VMF_TEST_ENGINE = WapFakeEngine $script:mig
        & pwsh -NoProfile -File $script:workerScript -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Wave 'wave-1' `
            -RunId (Split-Path $script:mig -Leaf) -WorkerId 'worker-t1' -WaveVersion $checked -IdleWaitSeconds 1 *> $null
        $LASTEXITCODE | Should -Be 0
        foreach ($id in WapIds $script:mig 'wave-1') { WapState $script:mig $id | Should -Be 'MIGRATED' }
    }

    It 'a worker: an edit to ITS wave between the checks and the worker is still caught - it takes no machine' {
        $checked = WapVersion (WapPlanText $script:mig) 'wave-1'
        WapSave $script:mig -Wave1 @{ keepSnapshotDays = 21 } | Out-Null
        $env:VMF_TEST_ENGINE = WapFakeEngine $script:mig
        $out = & pwsh -NoProfile -File $script:workerScript -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Wave 'wave-1' `
            -RunId (Split-Path $script:mig -Leaf) -WorkerId 'worker-t2' -WaveVersion $checked -IdleWaitSeconds 1 2>&1
        $LASTEXITCODE | Should -Be 3
        ($out -join ' ') | Should -Match 'The plan changed after wave wave-1 passed its start checks'
        foreach ($id in WapIds $script:mig 'wave-1') { WapState $script:mig $id | Should -Be '' }
        @(Get-ChildItem (Join-Path $script:mig 'leases') -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'a worker: a machine moved INTO its wave between the checks and the worker is caught too' {
        $checked = WapVersion (WapPlanText $script:mig) 'wave-1'
        $one = WapIds $script:mig 'wave-1'
        $two = WapIds $script:mig 'wave-2'
        WapSave $script:mig -Ids1 @($one + $two[0]) -Ids2 @($two[1]) | Out-Null
        $env:VMF_TEST_ENGINE = WapFakeEngine $script:mig
        & pwsh -NoProfile -File $script:workerScript -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Wave 'wave-1' `
            -RunId (Split-Path $script:mig -Leaf) -WorkerId 'worker-t3' -WaveVersion $checked -IdleWaitSeconds 1 *> $null
        $LASTEXITCODE | Should -Be 3
        WapState $script:mig $two[0] | Should -Be ''
    }

    It 'PLAN-WRITE-RACE-1 is still the whole plan: two saves of two different waves from one read give one 409' {
        $read = InModuleScope VmMigrationFactory -Parameters @{ t = (WapPlanText $script:mig) } { Get-VmfDocumentVersion -Text $t }
        $layout = { param([string]$Name, [int]$Days) @{ waves = @(
            [ordered]@{ name = 'wave-1'; vmIds = @(WapIds $script:mig 'wave-1'); keepSnapshotDays = $(if ($Name -eq 'wave-1') { $Days } else { 7 }) },
            [ordered]@{ name = 'wave-2'; vmIds = @(WapIds $script:mig 'wave-2'); keepSnapshotDays = $(if ($Name -eq 'wave-2') { $Days } else { 7 }) }) } }
        Set-VmfWavePlan -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Layout (& $layout 'wave-1' 21) -ExpectedPlanVersion $read -Confirm:$false | Out-Null
        { Set-VmfWavePlan -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Layout (& $layout 'wave-2' 14) -ExpectedPlanVersion $read -Confirm:$false } |
            Should -Throw '409:*'
        (WapPlan $script:mig).entries | Where-Object wave -eq 'wave-2' | ForEach-Object { [int]$_.policy.keepSnapshotDays | Should -Be 7 }
    }

    It 'APPR-2 is still the whole plan: an approval sent with the version shown before another wave changed is refused' {
        $shown = InModuleScope VmMigrationFactory -Parameters @{ t = (WapPlanText $script:mig) } { Get-VmfDocumentVersion -Text $t }
        Remove-Item (Join-Path $script:mig 'approvals' 'wave-1.json')
        WapSave $script:mig -Wave2 @{ keepSnapshotDays = 14 } | Out-Null
        { Approve-VmfWave -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Wave 'wave-1' -Note 'x' -ExpectedPlanHash $shown -OnBehalfOf $script:who } |
            Should -Throw '409:*'
        WapApprovalDoc $script:mig 'wave-1' | Should -BeNullOrEmpty
    }
}

Describe 'WAVE-APPROVE-1: "Sign off all" is one approval per wave' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((WapSku 'Standard_D2ds_v6'), (WapSku 'Standard_D2s_v6')) }
        $script:run = WapPlanned
        $script:mig = $script:run.Mig
        Approve-VmfPlan -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Note 'every wave read' -OnBehalfOf $script:who | Out-Null
        $script:decision = {
            InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig } { Get-VmfPlanRunDecision -RunPath $m -PlanPath (Join-Path $m 'plan.json') }
        }
        $script:finish = { param([string]$Wave)
            foreach ($id in WapIds $script:mig $Wave) {
                InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig; id = $id } {
                    New-VmfStateDoc -RunPath $m -RunId 'r' -VmId $id | Out-Null
                    Add-VmfStateTransition -RunPath $m -VmId $id -NewState 'MIGRATED' -Outcome ok | Out-Null
                }
            }
        }
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'writes one approval for each wave, each signing its own wave, and a v3 sign-off record' {
        $text = WapPlanText $script:mig
        foreach ($w in 'wave-1', 'wave-2') {
            $doc = WapApprovalDoc $script:mig $w
            $doc | Should -Not -BeNullOrEmpty -Because "$w has its own approval"
            $doc.schemaVersion | Should -Be 5
            $doc.wave | Should -BeExactly $w
            $doc.waveVersion | Should -BeExactly (WapVersion $text $w)
            $doc.approvedBy.identity | Should -Be 'approver@example.com'
            $doc.note | Should -Be 'every wave read'
        }
        (WapApprovalDoc $script:mig 'wave-1').waveVersion | Should -Not -Be (WapApprovalDoc $script:mig 'wave-2').waveVersion
        $pa = Get-Content (Join-Path $script:mig 'plan-approval.json') -Raw | ConvertFrom-Json
        $pa.schemaVersion | Should -Be 4 -Because 'SQL-TEMPDB-SIGNOFF-1 made it v4'
        @($pa.waves) | Should -Be @('wave-1', 'wave-2')
    }

    It 'a change to wave-2 after the sign-off asks again for wave-2 only, and the plan runs on to it once wave-2 is approved again' {
        & $script:finish 'wave-1'
        WapSave $script:mig -Wave2 @{ keepSnapshotDays = 14 } | Out-Null
        Confirm-VmfWaveOptions -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Wave 'wave-2' -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        (WapGate $script:mig 'wave-1').Pass | Should -BeTrue
        (WapGate $script:mig 'wave-2').Pass | Should -BeFalse
        # The consent stands; the run waits at wave-2's own approval.
        $d = & $script:decision
        $d.Reason | Should -Be 'gate'
        $d.GateWave | Should -Be 'wave-2'
        $d.GateCode | Should -Be 'notApproved'
        # The approver approves wave-2 alone. Nothing else is signed again.
        $before = (WapApprovalDoc $script:mig 'wave-1').approvedUtc
        WapApprove $script:mig 'wave-2'
        (WapApprovalDoc $script:mig 'wave-1').approvedUtc | Should -Be $before
        $d = & $script:decision
        $d.Reason | Should -Be 'start'
        $d.Wave | Should -Be 'wave-2'
        # Review 4: the decision says the version of the wave it judged, so the
        # start can be bound to it.
        $d.WaveVersion | Should -BeExactly (WapVersion (WapPlanText $script:mig) 'wave-2')
    }

    It 'a wave set to need no approval does not start BY ITSELF after it changed - only on an approval an approver gave' {
        # The review: a start nobody presses must rest on something an approver
        # signed. The sign-off wrote wave-2 an approval; the change removed it.
        & $script:finish 'wave-1'
        WapSave $script:mig -Wave2 @{ requireApproval = $false; keepSnapshotDays = 14 } | Out-Null
        Confirm-VmfWaveOptions -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Wave 'wave-2' -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        (WapGate $script:mig 'wave-2').Pass | Should -BeTrue -Because 'a person may still start it by hand'
        $d = & $script:decision
        $d.Reason | Should -Be 'gate'
        $d.GateWave | Should -Be 'wave-2'
        $d.GateCode | Should -Be 'signOffOutOfDate'
        $d.Detail | Should -Match 'Wave wave-2 changed after the plan was signed off, so it does not start by itself\.'
        WapApprove $script:mig 'wave-2'
        (& $script:decision).Wave | Should -Be 'wave-2' -Because 'an approver signed the wave as it is now'
    }

    It 'WAVE-APPROVE-TIMER-WORDS-1: the migrations list reads the reason the timer gives - signOffOutOfDate, not start' {
        # The summary in run-status.json is what the Migrations list and the
        # overview read. It said start (nothing holds the wave) while the timer
        # held the wave with signOffOutOfDate.
        & $script:finish 'wave-1'
        WapSave $script:mig -Wave2 @{ requireApproval = $false; keepSnapshotDays = 14 } | Out-Null
        Confirm-VmfWaveOptions -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Wave 'wave-2' -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        $summary = { InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig } {
                Update-VmfRunSummary -RunPath $m -Reason 'dailyCheck' | Out-Null
                (Read-VmfStoreJson -RunPath $m -RelPath 'run-status.json' -Depth 24).summary.next } }
        $d = & $script:decision
        $next = & $summary
        $next.wave | Should -Be 'wave-2'
        $next.waitsFor | Should -BeExactly $d.GateCode -Because 'the list reads the reason the timer records, from the same rule'
        $next.waitsFor | Should -BeExactly 'signOffOutOfDate'
        # An approver signs the wave as it is now: the timer starts it, and the list says start.
        WapApprove $script:mig 'wave-2'
        (& $script:decision).Reason | Should -Be 'start'
        (& $summary).waitsFor | Should -BeExactly 'start'
    }

    It 'WAVE-APPROVE-TIMER-WORDS-1: a wave the watchdog restarts is not asked the rule for a start nobody presses' {
        # A machine of wave-2 a decision re-armed, with no worker on it: the
        # resume watchdog restarts the wave on its start gates alone, as before.
        & $script:finish 'wave-1'
        WapSave $script:mig -Wave2 @{ requireApproval = $false; keepSnapshotDays = 14 } | Out-Null
        Confirm-VmfWaveOptions -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Wave 'wave-2' -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        $id = (WapIds $script:mig 'wave-2')[0]
        $next = InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig; id = $id } {
            New-VmfStateDoc -RunPath $m -RunId 'r' -VmId $id | Out-Null
            Add-VmfStateTransition -RunPath $m -VmId $id -NewState 'PRECHECK' -Outcome ok | Out-Null
            Update-VmfRunSummary -RunPath $m -Reason 'dailyCheck' | Out-Null
            (Read-VmfStoreJson -RunPath $m -RelPath 'run-status.json' -Depth 24).summary.next
        }
        $next.wave | Should -Be 'wave-2'
        $next.waitsFor | Should -BeExactly 'running'
    }

    It 'with the sign-off of this exact plan, a wave set to need no approval follows as before' {
        WapSave $script:mig -Wave2 @{ requireApproval = $false } | Out-Null
        Confirm-VmfWaveOptions -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Wave 'wave-2' -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        Approve-VmfPlan -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Note 'again' -OnBehalfOf $script:who | Out-Null
        [System.IO.File]::Delete((Join-Path $script:mig 'approvals' 'wave-2.json'))
        & $script:finish 'wave-1'
        (& $script:decision).Wave | Should -Be 'wave-2'
        # WAVE-APPROVE-TIMER-WORDS-1: and the list says start, as the timer does.
        $next = InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig } {
            Update-VmfRunSummary -RunPath $m -Reason 'dailyCheck' | Out-Null
            (Read-VmfStoreJson -RunPath $m -RelPath 'run-status.json' -Depth 24).summary.next
        }
        $next.waitsFor | Should -BeExactly 'start'
    }
}

Describe 'WAVE-APPROVE-1: approvals written before this change' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((WapSku 'Standard_D2ds_v6'), (WapSku 'Standard_D2s_v6')) }
        $script:run = WapPlanned
        $script:mig = $script:run.Mig
        # A v1 approval, as Approve-VmfWave wrote it: the whole plan's version.
        $hash = InModuleScope VmMigrationFactory -Parameters @{ t = (WapPlanText $script:mig) } { Get-VmfDocumentVersion -Text $t }
        New-Item -ItemType Directory -Path (Join-Path $script:mig 'approvals') -Force | Out-Null
        foreach ($w in 'wave-1', 'wave-2') {
            [ordered]@{ schemaVersion = 1; runId = 'r'; wave = $w; approvedBy = @{ identity = 'approver@example.com'; tenantId = 't' }
                approvedUtc = '2026-10-01T00:00:00Z'; planHash = $hash; note = 'old' } | ConvertTo-Json | Set-Content (Join-Path $script:mig 'approvals' "$w.json")
        }
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'OLD-VERSION-READERS-REMOVE-2: an approval with no waveVersion does not pass, even while the whole plan is the text it signed' {
        # Only an earlier version wrote one, and nothing is public before 1.0.
        (WapGate $script:mig 'wave-1').Pass | Should -BeFalse
        (WapGate $script:mig 'wave-2').Pass | Should -BeFalse
    }

    It 'after ANY change a v1 approval asks again - it cannot say which wave it saw - and is removed and named' {
        $r = WapSave $script:mig -Wave2 @{ keepSnapshotDays = 14 }
        @($r.ApprovalsInvalidated | Sort-Object) | Should -Be @('wave-1', 'wave-2')
        $gate = WapGate $script:mig 'wave-1'
        $gate.Pass | Should -BeFalse
        WapApprovalDoc $script:mig 'wave-1' | Should -BeNullOrEmpty
    }

    It 'the gate on a v1 approval that no longer matches says the plan changed for that wave' {
        # Left in place, as a writer from before might have: the gate decides.
        $plan = WapPlan $script:mig
        $plan.entries[0].target.size = 'Standard_D4s_v6'
        [System.IO.File]::WriteAllText((WapPlanPath $script:mig), ($plan | ConvertTo-Json -Depth 24), [System.Text.UTF8Encoding]::new($false))
        $gate = WapGate $script:mig 'wave-2'
        $gate.Pass | Should -BeFalse
        $gate.Code | Should -Be 'approvalOutOfDate'
        $gate.Detail | Should -Match 'The plan changed for wave wave-2 after it was approved\.'
    }
}

Describe 'WAVE-APPROVE-1: a decision keeps the approval of its wave' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((WapSku 'Standard_D2ds_v6'), (WapSku 'Standard_D2s_v6')) }
        $script:run = WapPlanned
        $script:mig = $script:run.Mig
        WapApprove $script:mig 'wave-1'
        WapApprove $script:mig 'wave-2'
        $script:decide = { param([switch]$StaleFirst, [switch]$NotApprover)
            InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig; stale = [bool]$StaleFirst; carry = (-not $NotApprover) } {
                $pp = Join-Path $m 'plan.json'
                if ($stale) {
                    # wave-1's approval made out of date before the decision.
                    $doc = Read-VmfStoreJson -RunPath $m -RelPath 'approvals/wave-1.json' -Depth 8
                    $doc.waveVersion = 'f' * 64
                    Write-VmfStoreJson -RunPath $m -RelPath 'approvals/wave-1.json' -Document $doc -Depth 8
                }
                $read = Read-VmfPlanFileVersioned -Path $pp
                $before = Get-VmfDecisionSnapshot -Text $read.Text -Wave 'wave-1'
                $plan = $read.Plan
                $entry = @($plan.entries | Where-Object { $_.wave -eq 'wave-1' })[0]
                $entry.policy | Add-Member -NotePropertyName onDDataFound -NotePropertyValue 'proceed' -Force
                $written = $plan | ConvertTo-Json -Depth 24
                Write-VmfTextDocumentIfVersion -Path $pp -Content $written -ExpectedVersion $read.Version
                $kept = Invoke-VmfDecisionCarryForward -RunPath $m -PlanPath $pp -Before $before -AfterText $written -VmId ([string]$entry.vmId) `
                    -Change 'onDDataFound=proceed' -ResolvedBy 'approver@example.com' -CarryWaveApproval:$carry
                $gone = @(Remove-VmfStaleWaveApprovals -RunPath $m -PlanPath $pp)
                [pscustomobject]@{ Kept = $kept; Gone = $gone }
            }
        }
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'an approval current before the decision is moved to the wave after it, with the decision written on it' {
        $r = & $script:decide
        $r.Kept.Approval | Should -BeTrue
        @($r.Gone) | Should -BeNullOrEmpty
        $doc = WapApprovalDoc $script:mig 'wave-1'
        $doc.schemaVersion | Should -Be 5
        $doc.waveVersion | Should -BeExactly (WapVersion (WapPlanText $script:mig) 'wave-1')
        @($doc.amendments).Count | Should -Be 1
        $doc.amendments[0].change | Should -Be 'onDDataFound=proceed'
        (WapGate $script:mig 'wave-1').Pass | Should -BeTrue
        (WapGate $script:mig 'wave-2').Pass | Should -BeTrue -Because 'the decision did not touch wave-2'
    }

    It 'the rule of 2026-10-10: a v3 sign-off moves only together with the wave approval' {
        Approve-VmfPlan -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Note 'every wave read' -OnBehalfOf $script:who | Out-Null
        $signed = (Get-Content (Join-Path $script:mig 'plan-approval.json') -Raw | ConvertFrom-Json).planHash
        $r = & $script:decide -NotApprover
        $r.Kept.SignOff | Should -BeFalse -Because 'an operator''s decision does not move a v3 sign-off'
        (Get-Content (Join-Path $script:mig 'plan-approval.json') -Raw | ConvertFrom-Json).planHash | Should -BeExactly $signed
        (WapGate $script:mig 'wave-1').Pass | Should -BeFalse -Because 'the sign-off of the earlier plan does not pass the changed wave'
    }

    It 'the rule of 2026-10-10: an approver''s decision moves a v3 sign-off with the wave approval' {
        Approve-VmfPlan -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Note 'every wave read' -OnBehalfOf $script:who | Out-Null
        $r = & $script:decide
        $r.Kept.Approval | Should -BeTrue
        $r.Kept.SignOff | Should -BeTrue
        $pa = Get-Content (Join-Path $script:mig 'plan-approval.json') -Raw | ConvertFrom-Json
        $pa.planHash | Should -BeExactly (InModuleScope VmMigrationFactory -Parameters @{ t = (WapPlanText $script:mig) } { Get-VmfDocumentVersion -Text $t })
        $pa.schemaVersion | Should -Be 4 -Because 'SQL-TEMPDB-SIGNOFF-1 made it v4'
    }

    It 'a decision that is not an approver accepting the one decision does not carry it: the wave asks again' {
        $r = & $script:decide -NotApprover
        $r.Kept.Approval | Should -BeFalse
        @($r.Gone) | Should -Be @('wave-1')
        (WapGate $script:mig 'wave-1').Pass | Should -BeFalse
        (WapGate $script:mig 'wave-2').Pass | Should -BeTrue
    }

    It 'an approval already out of date is not carried: a decision never covers an edit nobody approved' {
        $r = & $script:decide -StaleFirst
        $r.Kept.Approval | Should -BeFalse
        @($r.Gone) | Should -Be @('wave-1')
        (WapGate $script:mig 'wave-1').Pass | Should -BeFalse
        (WapGate $script:mig 'wave-2').Pass | Should -BeTrue
    }
}

Describe 'WAVE-APPROVE-1: through Resolve-VmfDecision, only an approver''s acceptance of the decision keeps the approval' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((WapSku 'Standard_D2ds_v6'), (WapSku 'Standard_D2s_v6')) }
        $script:run = WapPlanned
        $script:mig = $script:run.Mig
        WapApprove $script:mig 'wave-1'
        WapApprove $script:mig 'wave-2'
        $script:parked = (WapId 'app-01')
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig; vm = $script:parked } {
            New-VmfStateDoc -RunPath $m -RunId 'r' -VmId $vm -Wave 'wave-1' | Out-Null
            Add-VmfStateTransition -RunPath $m -VmId $vm -NewState 'NEEDS_DECISION' -Outcome ok -ReasonCode 'dataOnTempDrive' -Detail 'files on the temporary disk' | Out-Null
        }
        $script:resolve = { param([hashtable]$Change, [string[]]$Roles)
            Resolve-VmfDecision -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -VmId $script:parked -PolicyOverride $Change `
                -Note 'decided' -ResolvedBy 'someone@example.com' -ResolvedRoles $Roles
        }
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'an approver accepting the decision the machine waits for keeps the wave approval, and the machine is re-armed' {
        (& $script:resolve @{ onDDataFound = 'proceed' } @('Vmf.Approver')).NewState | Should -Be 'PRECHECK'
        @((WapApprovalDoc $script:mig 'wave-1').amendments).Count | Should -Be 1
        (WapGate $script:mig 'wave-1').Pass | Should -BeTrue
    }

    It 'an operator''s change to another setting asks again for the wave approval, and the machine is not re-armed' {
        { & $script:resolve @{ keepSnapshotDays = 14 } @('Vmf.Operator') } | Should -Throw '400: The change (keepSnapshotDays=14) is saved, but wave wave-1 cannot start now*'
        WapApprovalDoc $script:mig 'wave-1' | Should -BeNullOrEmpty
        (WapGate $script:mig 'wave-2').Pass | Should -BeTrue -Because 'another wave keeps its approval'
    }

    It 'an approver who sends another setting, or the decision with another value, does not keep it either' {
        { & $script:resolve @{ keepSnapshotDays = 14 } @('Vmf.Approver', 'Vmf.Operator') } | Should -Throw '400:*cannot start now*'
        WapApprovalDoc $script:mig 'wave-1' | Should -BeNullOrEmpty
    }

    It 'an operator who sends the accepting value does not keep it - the decision is the approver''s' {
        { & $script:resolve @{ onDDataFound = 'proceed' } @('Vmf.Operator') } | Should -Throw '400:*cannot start now*'
        WapApprovalDoc $script:mig 'wave-1' | Should -BeNullOrEmpty
    }
}

Describe 'WAVE-APPROVE-1: after "Sign off all", a decision keeps the sign-off only with the wave''s approval' {
    # The second review: a sign-off of the exact plan passes every wave at the
    # approval gate, and DECIDE-KEEP-1 carried it past ANY decision. So under a
    # v3 sign-off an operator's other setting removed the wave's approval, the
    # carried sign-off passed the wave anyway, the machine was re-armed and the
    # timer would start the wave - with no approver looking. The rule
    # (2026-10-10): an operator's decision asks again, an approver's carries.
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((WapSku 'Standard_D2ds_v6'), (WapSku 'Standard_D2s_v6')) }
        $script:run = WapPlanned
        $script:mig = $script:run.Mig
        Approve-VmfPlan -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -Note 'every wave read' -OnBehalfOf $script:who | Out-Null
        $script:parked = (WapId 'app-01')
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig; vm = $script:parked } {
            New-VmfStateDoc -RunPath $m -RunId 'r' -VmId $vm -Wave 'wave-1' | Out-Null
            Add-VmfStateTransition -RunPath $m -VmId $vm -NewState 'NEEDS_DECISION' -Outcome ok -ReasonCode 'dataOnTempDrive' -Detail 'files on the temporary disk' | Out-Null
        }
        $script:resolve = { param([hashtable]$Change, [string[]]$Roles)
            Resolve-VmfDecision -RunPath $script:mig -PlanPath (WapPlanPath $script:mig) -VmId $script:parked -PolicyOverride $Change `
                -Note 'decided' -ResolvedBy 'lead@example.com' -ResolvedRoles $Roles
        }
        $script:signOff = { Get-Content (Join-Path $script:mig 'plan-approval.json') -Raw | ConvertFrom-Json -Depth 10 }
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'an operator''s other setting: the sign-off is not moved, wave-1 asks again, wave-2 keeps its approval' {
        $before = (& $script:signOff).planHash
        { & $script:resolve @{ keepSnapshotDays = 14 } @('Vmf.Operator') } | Should -Throw '400:*cannot start now*'
        (& $script:signOff).planHash | Should -BeExactly $before
        $gate = WapGate $script:mig 'wave-1'
        $gate.Pass | Should -BeFalse
        $gate.Code | Should -Be 'notApproved'
        (WapGate $script:mig 'wave-2').Pass | Should -BeTrue
        (WapState $script:mig $script:parked) | Should -Be 'NEEDS_DECISION' -Because 'the machine is not re-armed'
    }

    It 'an approver accepting the decision the machine waits for keeps the wave approval and the sign-off' {
        (& $script:resolve @{ onDDataFound = 'proceed' } @('Vmf.Approver')).NewState | Should -Be 'PRECHECK'
        (& $script:signOff).planHash | Should -BeExactly (InModuleScope VmMigrationFactory -Parameters @{ t = (WapPlanText $script:mig) } { Get-VmfDocumentVersion -Text $t })
        (WapGate $script:mig 'wave-1').Pass | Should -BeTrue
        # Item 2: the approval keeps the name of the approver who gave it, and
        # gains an amendment that names the approver who decided.
        $doc = WapApprovalDoc $script:mig 'wave-1'
        $doc.approvedBy.identity | Should -Be 'approver@example.com'
        @($doc.amendments)[-1].by | Should -Be 'lead@example.com'
    }
}

Describe 'WAVE-APPROVE-1: the contract' {
    BeforeAll {
        $script:schema = Join-Path $script:repoRoot 'schemas' 'wave-approval.schema.json'
    }
    It 'the sample is a v4 approval (REBUILD-REMOVE-ACCEPT-1) and validates' {
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'wave-approval.sample.json') -Raw
        ($sample | ConvertFrom-Json).schemaVersion | Should -Be 5
        $sample | Test-Json -SchemaFile $script:schema | Should -BeTrue
    }
    It 'OLD-VERSION-READERS-REMOVE-1: a v1 approval does not validate, and an approval without its wave version does not' {
        $v1 = [ordered]@{ schemaVersion = 1; runId = 'r'; wave = 'w'; approvedBy = @{ identity = 'approver@example.com' }
            approvedUtc = '2026-10-01T00:00:00Z'; planHash = ('a' * 64); note = 'n' } | ConvertTo-Json
        $v1 | Test-Json -SchemaFile $script:schema -ErrorAction SilentlyContinue | Should -BeFalse
        $v2 = [ordered]@{ schemaVersion = 5; runId = 'r'; wave = 'w'; approvedBy = @{ identity = 'approver@example.com' }
            approvedUtc = '2026-10-01T00:00:00Z'; planHash = ('a' * 64); note = 'n' } | ConvertTo-Json
        $v2 | Test-Json -SchemaFile $script:schema -ErrorAction SilentlyContinue | Should -BeFalse
    }
    It 'what Approve-VmfWave and Approve-VmfPlan write validates' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((WapSku 'Standard_D2ds_v6'), (WapSku 'Standard_D2s_v6')) }
        $run = WapPlanned
        try {
            Approve-VmfPlan -RunPath $run.Mig -PlanPath (WapPlanPath $run.Mig) -Note 'n' -OnBehalfOf $script:who | Out-Null
            foreach ($w in 'wave-1', 'wave-2') {
                Get-Content (Join-Path $run.Mig 'approvals' "$w.json") -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
            }
            Get-Content (Join-Path $run.Mig 'plan-approval.json') -Raw |
                Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-approval.schema.json') | Should -BeTrue
        }
        finally { foreach ($d in $run.Scan, $run.Mig) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } } }
    }
    It 'the migration note exists' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match 'wave-approval v1 -> v2'
        $notes | Should -Match 'plan-approval v2 -> v3'
    }
}
