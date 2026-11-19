#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# WAVE-SAVE-FALSE-1 (GitHub issue 424): a save of the wave editor said "The
# waves changed, so the earlier quota check for wave wave-1, wave wave-2 no
# longer matched them and was removed" on a plan nobody had changed.
#
# THE CAUSE, measured here through the real plan writer and the real service
# function: the planner writes no `onSystemAssignedIdentity` into a new plan
# (Get-VmfDefaultWavePolicy does not carry it; the engine reads an absent value
# as 'stop' in Get-VmfPolicy). The wave editor sends 'stop' for every wave on
# every save. Set-VmfWavePlan compared the STORED value, $null, with 'stop',
# called that a change, and so judged EVERY wave touched - its quota check and
# its approval were removed. Only `throttle` read an absent value as its default.
#
# So the judgement now compares a setting's EFFECTIVE value - the stored value,
# or the engine's own default when it is absent (Get-VmfPolicy, which takes the
# wave defaults from Get-VmfDefaultWavePolicy) - both sides read the same way.
#
# The payload below is the one src/dashboard/waves.html sent before
# WAVE-LEVER-OVERRIDE-1: each wave's settings from its FIRST machine with the
# page's own defaults, all seven for every wave that is not running, and no
# list of changes. The service still takes it (a page from before, or the
# command line), and on these plans - no machine holding its own value - the
# first machine IS the card. The page's present payload is tested in
# WaveLeverOverride.Tests.ps1. It goes through JSON, as a request body does.

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:WsfSku([string]$Name, [string]$TempMb = '0') {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V2' }) }
    }
    function Global:WsfId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
    function Global:WsfVm([string]$Name, [string]$Environment) {
        [ordered]@{
            vmId = (WsfId $Name); name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @()
            classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; osVersion = '22_04-lts-gen2'
            sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = 'SCSI'
            dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; iacManaged = $false; hibernationEnabled = $false; availabilitySetId = ''
            identityType = 'None'; tags = @{ environment = $Environment }; blockers = @(); prepNeeded = @()
        }
    }
    function Global:WsfPrincipal {
        # Operator AND Approver: a setting moved to its accepting value is an
        # approver's act (DECIDE-2, APPR-LEVER-1), and this file is about the
        # judgement of a change, not about who may make it.
        $claims = @(@{ typ = 'preferred_username'; val = 'lead@example.com' },
                    @{ typ = 'roles'; val = 'Vmf.Operator' }, @{ typ = 'roles'; val = 'Vmf.Approver' })
        $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
        ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
    }
    function Global:WsfPlanText($mig) { InModuleScope VmMigrationFactory -Parameters @{ m = $mig } { Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $m -RelPath 'plan.json') } }
    function Global:WsfPlan($mig) { (WsfPlanText $mig) | ConvertFrom-Json -Depth 30 }

    # The flow, the way the app runs it: scan, review, targets, then the plan
    # operation - New-VmfPlan with waves made by a tag - and the quota check the
    # same operation records. Each wave is then approved and its settings
    # accepted, so a save that voids either can be seen.
    function Global:WsfPlanned {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wsf-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $vms = @((WsfVm 'app-01' 'dev'), (WsfVm 'app-02' 'dev'), (WsfVm 'web-01' 'prod'), (WsfVm 'web-02' 'prod'))
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
        # The quota check the plan operation records, one per wave (the engine's
        # Test-VmfQuota asks Azure; the record is what a save judges).
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig } {
            foreach ($w in 'wave-1', 'wave-2') {
                Write-VmfStoreJson -RunPath $m -RelPath "capacity/$w-centralus-d2ds.json" -Depth 12 -Document ([ordered]@{
                    schemaVersion = 8; wave = $w; region = 'centralus'; size = 'Standard_D2ds_v6'; count = 2; state = 'QUOTA_VERIFIED' })
            }
        }
        foreach ($w in 'wave-1', 'wave-2') {
            Confirm-VmfWaveOptions -RunPath $mig -PlanPath (Join-Path $mig 'plan.json') -Wave $w -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
            Approve-VmfWave -RunPath $mig -PlanPath (Join-Path $mig 'plan.json') -Wave $w -Note 'read and approved' -OnBehalfOf $who | Out-Null
        }
        @{ Scan = $rp; Mig = $mig }
    }

    # What src/dashboard/waves.html sends on Save, for the plan as stored.
    # $Edit changes the layout the way a person would on the page.
    function Global:WsfPageSave($mig, [scriptblock]$Edit) {
        $plan = WsfPlan $mig
        $rank = @($plan.waveOrder)
        $layout = [ordered]@{}
        $moving = @($plan.entries | Where-Object { [string]$_.path -in @('A', 'B') }) |
            Sort-Object { $rank.IndexOf([string]$_.wave) }
        foreach ($e in $moving) {
            $name = [string]$e.wave
            if (-not $name -or $name -eq 'unscheduled') { continue }
            if (-not $layout.Contains($name)) {
                $pol = $e.policy
                $or = { param($key, $default) if ($null -ne $pol.$key) { $pol.$key } else { $default } }
                $layout[$name] = [ordered]@{
                    capacityGate             = (& $or 'capacityGate' 'BestEffort')
                    # The page's `!== false`: only the boolean false is off.
                    # A string "false" is not, and neither is 0.
                    requireApproval          = (-not ($pol.requireApproval -is [bool] -and $pol.requireApproval -eq $false))
                    onDDataFound             = (& $or 'onDDataFound' 'stop')
                    keepSnapshotDays         = (& $or 'keepSnapshotDays' 7)
                    throttle                 = (& $or 'throttle' 15)   # MACHINES-AT-ONCE-RANGE-1: the page reads a missing number as Standard
                    vmIds                    = [System.Collections.Generic.List[string]]::new()
                }
            }
            $layout[$name].vmIds.Add([string]$e.vmId)
        }
        if ($Edit) { & $Edit $layout }
        $waves = @(foreach ($name in $layout.Keys) {
            $w = $layout[$name]
            [ordered]@{ name = $name; capacityGate = $w.capacityGate; requireApproval = $w.requireApproval
                onDDataFound = $w.onDDataFound
                keepSnapshotDays = $w.keepSnapshotDays
                throttle = $w.throttle; vmIds = @($w.vmIds) }
        })
        $version = InModuleScope VmMigrationFactory -Parameters @{ t = (WsfPlanText $mig) } { Get-VmfDocumentVersion -Text $t }
        $body = @{ waves = $waves; planVersion = $version } | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
        Invoke-VmfFacadeSetWaves -Principal (WsfPrincipal) -StorePath $mig -Waves $body.waves -PlanVersion $body.planVersion
    }
    function Global:WsfEvents($mig) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig } {
            @(Read-VmfStoreLines -RunPath $m -RelPath 'logs/events.jsonl' | ForEach-Object { $_ | ConvertFrom-Json })
        }
    }
    function Global:WsfApproved($mig, [string]$Wave) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig; w = $Wave } {
            (Test-VmfWaveApproval -RunPath $m -PlanPath (Join-Path $m 'plan.json') -Wave $w).Pass
        }
    }
    function Global:WsfAccepted($mig, [string]$Wave) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig; w = $Wave } {
            $plan = Read-VmfPlanDocument -RunPath $m
            (Test-VmfWaveOptionsAccepted -RunPath $m -Wave $w -Entries @(Get-VmfWaveOptionsEntries -Plan $plan -Wave $w)).Pass
        }
    }
}
AfterAll {
    foreach ($fn in 'WsfSku', 'WsfId', 'WsfVm', 'WsfPrincipal', 'WsfPlanText', 'WsfPlan', 'WsfPlanned', 'WsfPageSave', 'WsfEvents', 'WsfApproved', 'WsfAccepted') {
        Remove-Item "function:\$fn" -ErrorAction SilentlyContinue
    }
}

Describe 'WAVE-SAVE-FALSE-1 (issue 424): a save judges a wave changed only when it changed' {

    BeforeEach {
        $script:catalog = @((WsfSku 'Standard_D2ds_v6' '0'), (WsfSku 'Standard_D2s_v6' '0'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:run = WsfPlanned
        $script:mig = $script:run.Mig
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'the plan made by a tag has the two waves the issue names, and no system-assigned identity setting' {
        # The fixture is the issue's own shape. And the setting the page sends
        # that the planner does not write - the cause.
        $plan = WsfPlan $script:mig
        @($plan.waveOrder) | Should -Be @('wave-1', 'wave-2')
        foreach ($e in @($plan.entries)) { $e.policy.PSObject.Properties['onSystemAssignedIdentity'] | Should -BeNullOrEmpty }
        WsfApproved $script:mig 'wave-1' | Should -BeTrue
        WsfAccepted $script:mig 'wave-2' | Should -BeTrue
    }

    It 'a save of the untouched layout keeps every quota check, approval and acceptance, and says nothing changed' {
        $before = WsfPlanText $script:mig
        $logged = @(WsfEvents $script:mig).Count
        $r = WsfPageSave $script:mig
        @($r.CapacityChecksCleared) | Should -BeNullOrEmpty
        @($r.ApprovalsInvalidated) | Should -BeNullOrEmpty
        @($r.AcceptancesCleared) | Should -BeNullOrEmpty
        $r.MovedCount | Should -Be 0
        $r.Unchanged | Should -BeTrue
        foreach ($w in 'wave-1', 'wave-2') {
            Test-Path (Join-Path $script:mig 'capacity' "$w-centralus-d2ds.json") | Should -BeTrue -Because "the quota check of $w describes the wave as it still is"
            Test-Path (Join-Path $script:mig 'approvals' "$w.json") | Should -BeTrue
            # The approval signs the plan TEXT, so the files staying is not
            # enough: the gate must still pass.
            WsfApproved $script:mig $w | Should -BeTrue -Because "nothing changed since $w was approved"
            WsfAccepted $script:mig $w | Should -BeTrue
        }
        WsfPlanText $script:mig | Should -BeExactly $before -Because 'an unchanged plan is not written again (SAVE-STUCK-1, on the service side)'
        $said = @(WsfEvents $script:mig | Select-Object -Skip $logged | ForEach-Object { [string]$_.detail })
        ($said -join ' ') | Should -Not -Match 'changed|removed|cleared' -Because 'nothing changed, so no line may say it did'
    }

    It 'a plan written before a setting existed reads it as its default: <Field>' -ForEach @(
        @{ Field = 'capacityGate' }, @{ Field = 'requireApproval' }, @{ Field = 'onDDataFound' }
        @{ Field = 'keepSnapshotDays' }, @{ Field = 'throttle' }) {
        # Remove the setting from every stored entry, as an older plan has it.
        # The identity setting is STORED for every other case, so each case
        # fails on its own setting and not on the identity cause (review).
        $plan = WsfPlan $script:mig
        foreach ($e in @($plan.entries)) {
            if ($Field -ne 'onSystemAssignedIdentity') { $e.policy | Add-Member -NotePropertyName onSystemAssignedIdentity -NotePropertyValue 'stop' -Force }
            $e.policy.PSObject.Properties.Remove($Field)
        }
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig; d = $plan } { Write-VmfStoreJson -RunPath $m -RelPath 'plan.json' -Document $d -Depth 30 }
        $r = WsfPageSave $script:mig
        @($r.CapacityChecksCleared) | Should -BeNullOrEmpty -Because "an absent $Field MEANT its default, which is what the page sent"
        @($r.ApprovalsInvalidated) | Should -BeNullOrEmpty
        $r.Unchanged | Should -BeTrue
    }

    It 'a stored value of another type is the same value: <Field> stored as <Stored>' -ForEach @(
        @{ Field = 'keepSnapshotDays'; Stored = '07' }, @{ Field = 'throttle'; Stored = '015' }
        @{ Field = 'requireApproval'; Stored = 1 }, @{ Field = 'requireApproval'; Stored = 'false' }) {
        # A plan edited by hand or written by another tool. Each of these the
        # old text compare got wrong: "07" against 7, and 1 or "false" against
        # true. The page sends 7 and 15 as it reads them, and true for 1 and for
        # "false" (only the boolean false is off) - and the engine's gate reads
        # 1 and "false" as required too ([bool]). So each is one setting.
        $plan = WsfPlan $script:mig
        foreach ($e in @($plan.entries)) {
            $e.policy | Add-Member -NotePropertyName onSystemAssignedIdentity -NotePropertyValue 'stop' -Force
            $e.policy | Add-Member -NotePropertyName $Field -NotePropertyValue $Stored -Force
        }
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig; d = $plan } { Write-VmfStoreJson -RunPath $m -RelPath 'plan.json' -Document $d -Depth 30 }
        $r = WsfPageSave $script:mig
        @($r.CapacityChecksCleared) | Should -BeNullOrEmpty
        $r.Unchanged | Should -BeTrue
    }

    It '<Field> changed alone on wave-2 touches only wave-2, and the log names it' -ForEach @(
        @{ Field = 'capacityGate';             To = 'Reserved';  Said = "'On-demand capacity reservation for this wave' changed from No to Yes" }
        @{ Field = 'requireApproval';          To = $false;      Said = "'Someone must sign off before this wave runs' changed from on to off" }
        @{ Field = 'onDDataFound';             To = 'proceed';   Said = "'If files are found on the temporary disk' changed from Stop and ask to Continue" }
        @{ Field = 'keepSnapshotDays';         To = 14;          Said = "'How long the snapshot is kept' changed from 7 days to 14 days" }
        @{ Field = 'throttle';                 To = 5;           Said = "'How many machines at once' changed from 15 to 5" }) {
        $edit = { param($layout) $layout['wave-2'][$Field] = $To }.GetNewClosure()
        $r = WsfPageSave $script:mig -Edit $edit
        @($r.CapacityChecksCleared) | Should -Be @('wave-2')
        @($r.AcceptancesCleared) | Should -Be @('wave-2')
        Test-Path (Join-Path $script:mig 'capacity' 'wave-1-centralus-d2ds.json') | Should -BeTrue -Because 'wave-1 did not change'
        WsfAccepted $script:mig 'wave-1' | Should -BeTrue -Because 'an acceptance binds only its own wave'
        # WAVE-APPROVE-1: rewritten. An approval bound the WHOLE plan text, so
        # this pinned wave-1's approval removed and named. An approval now signs
        # its own wave (2026-10-05), so wave-1 keeps it and still passes
        # the engine's gate.
        @($r.ApprovalsInvalidated) | Should -Be @('wave-2')
        Test-Path (Join-Path $script:mig 'approvals' 'wave-1.json') | Should -BeTrue
        WsfApproved $script:mig 'wave-1' | Should -BeTrue -Because 'an approval binds only its own wave'
        $events = @(WsfEvents $script:mig)
        $quota = [string](@($events | Where-Object { $_.step -eq 'capacity' -and $_.outcome -eq 'warn' })[-1].detail)
        $quota | Should -Match ([regex]::Escape("for wave wave-2 no longer matched them and was removed."))
        $quota | Should -Match ([regex]::Escape("In wave wave-2, the setting $Said."))
        $quota | Should -Not -Match 'wave-1' -Because 'the line names only the wave that changed'
        $plan = [string](@($events | Where-Object { $_.step -eq 'plan' })[-1].detail)
        $plan | Should -Match ([regex]::Escape("In wave wave-2, the setting $Said."))
        $plan | Should -Not -Match ([regex]::Escape('The approval of wave wave-1')) -Because 'wave-1 kept its approval'
        $plan | Should -Not -Match ([regex]::Escape('The approval of wave wave-2 signed')) -Because 'wave-2 says what changed in it instead'
        # The new value is written, and the other wave keeps what it had.
        $after = WsfPlan $script:mig
        $w2 = @($after.entries | Where-Object { $_.wave -eq 'wave-2' })
        foreach ($e in $w2) { [string]$e.policy.$Field | Should -Be ([string]$To) }

    }

    It 'a machine moved touches both waves, and the log names the machine and both waves' {
        $edit = {
            param($layout)
            $id = WsfId 'web-01'
            $layout['wave-2'].vmIds.Remove($id) | Out-Null
            $layout['wave-1'].vmIds.Add($id)
        }
        $r = WsfPageSave $script:mig -Edit $edit
        $r.MovedCount | Should -Be 1
        @($r.CapacityChecksCleared) | Should -Be @('wave-1', 'wave-2')
        @($r.ApprovalsInvalidated | Sort-Object) | Should -Be @('wave-1', 'wave-2')
        $quota = [string](@(WsfEvents $script:mig | Where-Object { $_.step -eq 'capacity' -and $_.outcome -eq 'warn' })[-1].detail)
        $quota | Should -Match ([regex]::Escape('In wave wave-1, machine web-01 moved in from wave wave-2.'))
        $quota | Should -Match ([regex]::Escape('In wave wave-2, machine web-01 moved to wave wave-1.'))
    }

    It 'more than five changes in a wave are counted, in the active voice' {
        $edit = {
            param($layout)
            $w = $layout['wave-2']
            $w.capacityGate = 'Reserved'; $w.requireApproval = $false; $w.onDDataFound = 'proceed'
            $w.keepSnapshotDays = 14; $w.throttle = 5
            # REBUILD-REMOVE-ACCEPT-1: the identity setting is gone, so a machine
            # moved in is the sixth change.
            $id = WsfId 'app-01'
            $layout['wave-1'].vmIds.Remove($id) | Out-Null
            $layout['wave-2'].vmIds.Add($id)
        }
        WsfPageSave $script:mig -Edit $edit | Out-Null
        $quota = [string](@(WsfEvents $script:mig | Where-Object { $_.step -eq 'capacity' -and $_.outcome -eq 'warn' })[-1].detail)
        ([regex]::Matches($quota, 'In wave wave-2, ')).Count | Should -Be 5
        # AN-PROCEED-NETVSC-1: the driver floor has no Continue, so six
        # changes here, and one more is said in the singular.
        $quota | Should -Match ([regex]::Escape('Wave wave-2 has 1 more change.'))
    }
}

Describe 'WAVE-SAVE-FALSE-1: the page and the service read a missing setting as the engine does' {
    # A changed default in one place brings the false change back: the page
    # would send one value and the save would compare another. So each reading
    # is held to the engine's (Get-VmfPolicy, which takes the wave defaults
    # from Get-VmfDefaultWavePolicy).
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:page = Get-VmfCodeOnly -Language CStyle -Text ((Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html')))
        $script:engine = InModuleScope VmMigrationFactory {
            $empty = [pscustomobject]@{ policy = [pscustomobject]@{} }
            $d = @{}
            foreach ($k in 'capacityGate', 'requireApproval', 'onDDataFound', 'onDriverBelowFloor', 'keepSnapshotDays', 'throttle') {
                $d[$k] = Get-VmfPolicy -PlanEntry $empty -Name $k
            }
            $d
        }
    }

    # WAVE-LEVER-OVERRIDE-1: the card is no longer drawn from the first
    # machine, field by field, so the defaults moved into one table the page
    # reads every setting through (WAVE_DEFAULTS, read by leverValue). These
    # read that table and that function instead of the old lines.
    It 'the wave editor reads a missing <Field> as the engine does' -ForEach @(
        @{ Field = 'capacityGate' }, @{ Field = 'onDDataFound' }
        @{ Field = 'keepSnapshotDays' }, @{ Field = 'throttle' }) {
        # ACCEPT-FIRST-MACHINE-1: the table and leverValue are in help.js, so
        # the wave editor and the acceptance read one table; the page names it.
        $script:page | Should -Match ([regex]::Escape('const WAVE_DEFAULTS = VmfHelp.waveSettingDefaults();'))
        $help = Get-VmfCodeOnly -Language CStyle -Text (Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw)
        $block = [regex]::Match($help, 'function waveSettingDefaults\(\) \{\s*return \{(?<b>[^}]*)\}').Groups['b'].Value
        $block | Should -Not -BeNullOrEmpty -Because 'help.js keeps the defaults in one table'
        # MACHINES-AT-ONCE-RANGE-1: the default number of machines at once is help.js's own.
        $m = [regex]::Match($block, "$($Field): '?(WAVE_DEFAULT_WORKERS|[A-Za-z0-9]+)'?")
        $m.Success | Should -BeTrue -Because "the table holds a default for $Field"
        $value = if ($m.Groups[1].Value -eq 'WAVE_DEFAULT_WORKERS') { [regex]::Match($help, 'const WAVE_DEFAULT_WORKERS = (\d+);').Groups[1].Value } else { $m.Groups[1].Value }
        $value | Should -Be ([string]$script:engine[$Field])
        $help | Should -Match ([regex]::Escape('e?.policy?.[field] ?? waveSettingDefaults()[field]')) -Because 'every setting is read through the table'
    }

    It 'the wave editor reads a missing sign-off as required, as the engine does' {
        $script:engine['requireApproval'] | Should -BeTrue
        # SIGNOFF-NULL-1: by the one rule in help.js; tests/js/signoff-null.test.js runs it.
        # ACCEPT-FIRST-MACHINE-1: leverValue is in help.js, and the page names it from there.
        $script:page | Should -Match ([regex]::Escape('const { leverValue, ownDecision, keepsOwn, waveCard } = VmfHelp;'))
        Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw | Should -Match ([regex]::Escape("if (field === 'requireApproval') { return approvalRequired(e); }"))
    }

    It 'a new wave on the page starts with the engine''s defaults: <Field>' -ForEach @(
        @{ Field = 'capacityGate' }, @{ Field = 'requireApproval' }, @{ Field = 'onDDataFound' }
        @{ Field = 'keepSnapshotDays' }, @{ Field = 'throttle' }) {
        $block = [regex]::Match($script:page, "layout\.set\(n, \{(?<b>[^}]*)\}\)").Groups['b'].Value
        $block | Should -Not -BeNullOrEmpty -Because 'Add a wave builds the new wave here'
        # MACHINES-AT-ONCE-RANGE-1: the default number of machines at once is help.js's own.
        $m = [regex]::Match($block, "$($Field): '?(VmfHelp\.WAVE_DEFAULT_WORKERS|[A-Za-z0-9]+)'?")
        $m.Success | Should -BeTrue
        # Should -Be ignores case: the page writes true, the engine True.
        $value = if ($m.Groups[1].Value -eq 'VmfHelp.WAVE_DEFAULT_WORKERS') { [regex]::Match((Get-Content (Join-Path $PSScriptRoot '..' '..' 'src' 'dashboard' 'help.js') -Raw), 'const WAVE_DEFAULT_WORKERS = (\d+);').Groups[1].Value } else { $m.Groups[1].Value }
        $value | Should -Be ([string]$script:engine[$Field])
    }

    It 'the service reads a missing sign-off as required (Get-VmfFacadeApprovalRemovals)' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wsf-f-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ r = $rp } {
                Initialize-VmfRun -RunPath $r -RunId 'wsf-f' | Out-Null
                Write-VmfStoreJson -RunPath $r -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{ schemaVersion = 8
                    entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/a'; wave = 'w'; path = 'A'; assessment = @{}; target = @{ size = 's' }; policy = [ordered]@{} }) })
            }
            $taken = @(InModuleScope FacadeCore -Parameters @{ r = $rp } { Get-VmfFacadeApprovalRemovals -StorePath $r -Requested @{ '/s/rg/vm/a' = $false } })
            # Taken off = it was on. The engine says the same of a missing value.
            ($taken.Count -eq 1) | Should -Be ([bool]$script:engine['requireApproval'])
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }

    It 'the service reads a missing <Field> as the engine does (Get-VmfFacadeDecisionsTaken)' -ForEach @(
        # AN-PROCEED-NETVSC-1: onDriverBelowFloor has no Continue, so asking for
        # one is refused by the save and is never a decision taken.
        @{ Field = 'onDDataFound' }) {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wsf-f-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ r = $rp } {
                Initialize-VmfRun -RunPath $r -RunId 'wsf-f' | Out-Null
                Write-VmfStoreJson -RunPath $r -RelPath 'plan.json' -Depth 12 -Document ([ordered]@{ schemaVersion = 8
                    entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/a'; wave = 'w'; path = 'A'; assessment = @{}; target = @{ size = 's' }; policy = [ordered]@{} }) })
            }
            $taken = @(InModuleScope FacadeCore -Parameters @{ r = $rp; f = $Field } { Get-VmfFacadeDecisionsTaken -StorePath $r -Requested @{ '/s/rg/vm/a' = @{ $f = 'proceed' } } })
            # Asking for 'proceed' is a decision only when the missing value
            # is read as something else - the engine's default.
            ($taken.Count -eq 1) | Should -Be ($script:engine[$Field] -ne 'proceed')
            $script:engine[$Field] | Should -Be 'stop'
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }
}

Describe 'WAVE-SAVE-FALSE-1: one place knows each default' {
    It 'the engine reads every wave default from the set a new plan is written with' {
        InModuleScope VmMigrationFactory {
            $empty = [pscustomobject]@{ policy = [pscustomobject]@{} }
            $wave = Get-VmfDefaultWavePolicy
            foreach ($k in @($wave.Keys)) {
                Get-VmfPolicy -PlanEntry $empty -Name $k | Should -Be $wave[$k] -Because "an absent $k means the default a new plan is written with"
            }
            # And the one the planner does not write still has the engine's reading.
            # REBUILD-REMOVE-ENGINE-1: onSystemAssignedIdentity is gone with its last reader.
            Get-VmfPolicy -PlanEntry $empty -Name 'onSystemAssignedIdentity' | Should -BeNullOrEmpty
            # MANUAL-REVIEW-1: bootableClone is gone with its stop; it has no default.
            Get-VmfPolicy -PlanEntry $empty -Name 'bootableClone' | Should -BeNullOrEmpty
        }
    }

    # WAVE-LEVER-OVERRIDE-1 moved the comparison out of Set-VmfWavePlan into
    # Get-VmfWaveSettingWrites, the one rule the writer and the service's role
    # checks share. The rule this pinned holds there, and the writer must ask it.
    It 'Set-VmfWavePlan judges through Get-VmfWaveSettingWrites, which asks Get-VmfPolicy and keeps no default of its own' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $writer = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Set-VmfWavePlan.ps1')
        $writer | Should -Match 'Get-VmfWaveSettingWrites -Entries \$entries'
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'WaveSettings.ps1')
        $code | Should -Match 'Get-VmfPolicy -PlanEntry \$entry -Name \$field'
        $code | Should -Not -Match "\`$existing = 3"
        $writer | Should -Not -Match "\`$existing = 3"
    }
}
