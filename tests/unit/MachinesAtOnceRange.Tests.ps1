#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MACHINES-AT-ONCE-RANGE-1: "How many machines at once" is four choices, one
# setting per wave, and the limit is 60 everywhere.
#
# Found 2026-11-04: machines per wave and machines in this start did not
# always match the wave settings, and a default of 3 was very low; a range
# fits better. Ruling, 2026-11-06: four tiers - Pilot 5, Standard 15
# (the default, one engine container), Large 30 (two containers), Maximum 60
# (four containers, the editor checks the cores) - and "it must be clear with
# the choice what each means (machines at once)".
#
# So: ONE list of the four choices in the module and ONE in help.js, held to
# each other here; the planner writes Standard; every writer of the plan writes
# one of the four (plan-entry v27), and ATONCE-EARLIER-1 took any other number
# out of the contract and out of the wave editor. And a start never carries a number of its own:
# the Run it step and the start dialog used to set one for one start only, so
# the screen and the engine could disagree. The service now reads the wave's
# own number for every start, now or scheduled.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
    $script:core = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw

    function Script:MarId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
    function Script:MarRun {
        param([hashtable[]]$Vms)
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-mar-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'mar-test' | Out-Null }
        $entries = foreach ($v in $Vms) {
            $policy = [ordered]@{ capacityGate = 'BestEffort'; requireApproval = $true }
            if ($v.ContainsKey('throttle')) { $policy.throttle = $v.throttle }
            [ordered]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = (Script:MarId $v.name)
                wave = $v.wave; appGroup = $v.name
                assessment = [ordered]@{ availabilitySetId = ''; location = 'centralus' }
                target = [ordered]@{ size = 'Standard_D2s_v6' }
                path = 'A'
                policy = $policy
            }
        }
        $doc = [ordered]@{ schemaVersion = 1; entries = @($entries) }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; doc = $doc } {
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $doc -Depth 24
        }
        $rp
    }
    function Script:MarPlan([string]$RunPath) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath } { Read-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 }
    }
    function Script:MarThrottle([string]$RunPath, [string]$Name) {
        $e = @((Script:MarPlan $RunPath).entries | Where-Object { $_.vmId -eq (Script:MarId $Name) })[0]
        if ($e.policy.PSObject.Properties['throttle']) { $e.policy.throttle } else { $null }
    }
    # The text of one function in a file, comments removed.
    function Script:MarFunction([string]$Path, [string]$Name) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
        if (-not $fn) { throw "no function $Name in $Path" }
        Get-VmfCodeOnly -Text $fn.Extent.Text -Language PowerShell
    }
}

Describe 'MACHINES-AT-ONCE-RANGE-1: the four choices, written down once on each side' {
    It 'the module holds Pilot 5, Standard 15, Large 30 and Maximum 60, in that order' {
        $tiers = @(InModuleScope VmMigrationFactory { Get-VmfThrottleTiers })
        ($tiers | ForEach-Object { "$($_.Id)=$($_.Machines)" }) -join ',' | Should -Be 'pilot=5,standard=15,large=30,maximum=60'
    }

    It 'Standard is the default a new plan gets' {
        (InModuleScope VmMigrationFactory { Get-VmfDefaultWavePolicy }).throttle | Should -Be 15
    }

    It 'help.js holds the same four, the same default, and the same 15 machines a container as the service' {
        $m = [regex]::Match($script:help, '(?s)const WAVE_TIERS = \[(.*?)\];')
        $m.Success | Should -BeTrue -Because 'help.js declares the four choices once'
        $pairs = @([regex]::Matches($m.Groups[1].Value, "id: '(\w+)', machines: (\d+)") | ForEach-Object { "$($_.Groups[1].Value)=$($_.Groups[2].Value)" })
        $pairs -join ',' | Should -Be 'pilot=5,standard=15,large=30,maximum=60'
        $script:help | Should -Match 'const WAVE_DEFAULT_WORKERS = 15;'
        $script:help | Should -Match 'const WAVE_PER_CONTAINER = 15;'
        $script:help | Should -Match 'const WAVE_MAX_WORKERS = 60;'
        # The service splits a wave over containers of 15 (SCALE-2).
        (Get-VmfFacadeWaveContainers -Workers 30).containers | Should -Be 2
        (Get-VmfFacadeWaveContainers -Workers 60).containers | Should -Be 4
        (Get-VmfFacadeWaveContainers -Workers 15).containers | Should -Be 1
    }
}

Describe 'MACHINES-AT-ONCE-RANGE-1: the plan contract, v27' {
    BeforeAll {
        $script:schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json -Depth 40
    }

    It 'is version 27 in the module, the schema and the sample, with a migration note' {
        InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion | Should -Be 37 }
        $script:schema.properties.schemaVersion.const | Should -Be 37
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json') -Raw | ConvertFrom-Json
        $sample.schemaVersion | Should -Be 37
        $sample.policy.throttle | Should -Be 15
        Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw | Should -Match 'plan-entry v26 -> v27'
    }

    It 'the limit is 60, and the contract lists the four choices only (ATONCE-EARLIER-1)' {
        $t = $script:schema.properties.policy.properties.throttle
        @($t.enum) | Should -Be @(5, 15, 30, 60)
        $t.description | Should -Not -Match '\b20\b'
        $t.description | Should -Match '5, 15, 30'
        $contract = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'PlanContract.ps1') -Raw
        $contract | Should -Not -Match '1 to 20'
    }

    It 'a policy written by the plan takes one of the four, and nothing else' {
        foreach ($n in 5, 15, 30, 60) {
            (InModuleScope VmMigrationFactory -Parameters @{ n = $n } { Test-VmfPolicyOverride -Override @{ throttle = $n } }).Ok | Should -BeTrue -Because "$n is a choice"
        }
        foreach ($n in 1, 3, 7, 16, 40, 61) {
            $r = InModuleScope VmMigrationFactory -Parameters @{ n = $n } { Test-VmfPolicyOverride -Override @{ throttle = $n } }
            $r.Ok | Should -BeFalse -Because "$n is not one of the four choices"
            $r.Detail | Should -Match '5, 15, 30 or 60'
        }
    }

}

Describe 'MACHINES-AT-ONCE-RANGE-1: one reading of a wave''s number' {
    It 'is the first machine that has a number, and the default when none has' {
        $entries = @(
            [pscustomobject]@{ wave = 'w1'; policy = [pscustomobject]@{ capacityGate = 'BestEffort' } }
            [pscustomobject]@{ wave = 'w1'; policy = [pscustomobject]@{ throttle = 30 } }
            [pscustomobject]@{ wave = 'w1'; policy = [pscustomobject]@{ throttle = 5 } })
        InModuleScope VmMigrationFactory -Parameters @{ e = $entries } { Get-VmfWaveThrottle -Entries $e } | Should -Be 30
        $none = @([pscustomobject]@{ wave = 'w1'; policy = [pscustomobject]@{ capacityGate = 'BestEffort' } })
        InModuleScope VmMigrationFactory -Parameters @{ e = $none } { Get-VmfWaveThrottle -Entries $e } | Should -Be 15 -Because 'a machine with no number reads as the default, as Get-VmfPolicy reads it'
    }

    It 'the signed-off plan starts its next wave at that number' {
        $code = Script:MarFunction (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'PlanRun.ps1') 'Get-VmfNextPlanWave'
        $code | Should -Match 'Get-VmfWaveThrottle -Entries \$mine'
        $code | Should -Not -Match 'else \{ 3 \}'
    }

    It 'the window check answers by the wave''s own number' {
        $vms = @(1..30 | ForEach-Object { @{ name = "m$_"; wave = 'w1'; throttle = 30 } })
        $rp = Script:MarRun -Vms $vms
        try {
            # 30 resizes at 10 minutes: 30 at once is 13 minutes with the safety
            # factor, 3 at once would be 125.
            $fit = Test-VmfWaveWindow -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Wave 'w1' -WindowMinutes 20
            $fit.Throttle | Should -Be 30
            $fit.Fits | Should -BeTrue
        }
        finally { Remove-Item $rp -Recurse -Force }
    }

    It 'the window check reads the wave''s own number and takes none from its caller' {
        (Get-Command Test-VmfWaveWindow).Parameters.ContainsKey('Throttle') | Should -BeFalse
        $code = Script:MarFunction (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Test-VmfWaveWindow.ps1') 'Test-VmfWaveWindow'
        $code | Should -Match 'Get-VmfWaveThrottle'
    }
}

Describe 'MACHINES-AT-ONCE-RANGE-1: the wave editor writes one of the four' {
    BeforeEach {
        $script:run = Script:MarRun -Vms @(
            @{ name = 'web1'; wave = 'w1'; throttle = 15 }, @{ name = 'web2'; wave = 'w1'; throttle = 15 },
            @{ name = 'old1'; wave = 'old'; throttle = 7 }, @{ name = 'old2'; wave = 'old'; throttle = 7 })
        $script:planPath = Join-Path $script:run 'plan.json'
    }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'writes a choice' {
        Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -ChangedBy 'lead@example.com' -Layout @{
            waves = @(@{ name = 'w1'; throttle = 30; changed = @{ throttle = 15 }; vmIds = @((Script:MarId 'web1'), (Script:MarId 'web2')) }) } | Out-Null
        Script:MarThrottle $script:run 'web1' | Should -Be 30
        Script:MarThrottle $script:run 'web2' | Should -Be 30
    }

    It 'refuses a number that is not a choice, by the label, and writes nothing' {
        { Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -ChangedBy 'lead@example.com' -Layout @{
            waves = @(@{ name = 'w1'; throttle = 12; changed = @{ throttle = 15 }; vmIds = @((Script:MarId 'web1'), (Script:MarId 'web2')) }) } } |
            Should -Throw '*How many machines at once*5, 15, 30 or 60*'
        Script:MarThrottle $script:run 'web1' | Should -Be 15
    }

    It 'refuses it from a layout with no list of changes too (the command line)' {
        { Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -Layout @{
            waves = @(@{ name = 'w1'; throttle = 20; vmIds = @((Script:MarId 'web1'), (Script:MarId 'web2')) }) } } |
            Should -Throw '*5, 15, 30 or 60*'
    }

    It 'ATONCE-EARLIER-1: refuses a wave whose number is not a choice, even when the person did not change it, and writes nothing' {
        { Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -ChangedBy 'lead@example.com' -Layout @{
            waves = @(@{ name = 'old'; throttle = 7; keepSnapshotDays = 9; changed = @{ keepSnapshotDays = 7 }; vmIds = @((Script:MarId 'old1'), (Script:MarId 'old2')) }) } } |
            Should -Throw '*5, 15, 30 or 60*'
        (@((Script:MarPlan $script:run).entries | Where-Object { $_.vmId -eq (Script:MarId 'old1') })[0]).policy.keepSnapshotDays | Should -Not -Be 9
    }

    It 'refuses a machine joining a wave whose number is not a choice' {
        { Set-VmfWavePlan -RunPath $script:run -PlanPath $script:planPath -ChangedBy 'lead@example.com' -Layout @{
            waves = @(@{ name = 'old'; throttle = 7; changed = @{}; vmIds = @((Script:MarId 'old1'), (Script:MarId 'old2'), (Script:MarId 'web1')) }
                      @{ name = 'w1'; throttle = 15; changed = @{}; vmIds = @((Script:MarId 'web2')) }) } } |
            Should -Throw '*5, 15, 30 or 60*'
        @((Script:MarPlan $script:run).entries | Where-Object { $_.vmId -eq (Script:MarId 'web1') })[0].wave | Should -Be 'w1'
    }
}

Describe 'MACHINES-AT-ONCE-RANGE-1: a start carries no number of its own' {
    It 'the start endpoint and the schedule endpoint do not read one from the request' {
        foreach ($f in 'PostStartEngine', 'PostSchedule') {
            $code = Get-VmfCodeOnly -Text (Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' $f 'run.ps1') -Raw) -Language PowerShell
            $code | Should -Not -Match 'throttle' -Because "$f takes the wave's own number"
        }
    }

    It 'a schedule records no number, and takes none' {
        (Get-Command Set-VmfWaveSchedule).Parameters.ContainsKey('Throttle') | Should -BeFalse
        (Get-Command Invoke-VmfFacadeSchedule).Parameters.ContainsKey('Throttle') | Should -BeFalse
        $rp = Script:MarRun -Vms @(@{ name = 'web1'; wave = 'w1'; throttle = 30 })
        try {
            $doc = Set-VmfWaveSchedule -RunPath $rp -Wave 'w1' -RunAtUtc (Get-Date).ToUniversalTime().AddHours(2) -ScheduledBy 'lead@example.com' -Note 'window'
            $doc.PSObject.Properties['throttle'] | Should -BeNullOrEmpty
        }
        finally { Remove-Item $rp -Recurse -Force }
    }

    It 'a schedule is checked against the wave''s own number' {
        $rp = Script:MarRun -Vms @(@{ name = 'web1'; wave = 'w1'; throttle = 60 })
        try {
            $script:asked = @()
            Mock Get-VmfFacadeWaveContainers -ModuleName FacadeCore { $script:asked += $Workers; [pscustomobject]@{ workers = $Workers; containers = 1; perContainer = @($Workers); perContainerMax = 15 } }
            Mock Get-VmfFacadeEngineJob -ModuleName FacadeCore { throw 'no job here' }
            Mock Get-VmfFacadePlanPath -ModuleName FacadeCore { param($StorePath) Join-Path $StorePath 'plan.json' }
            $principal = [pscustomobject]@{ Identity = 'lead@example.com'; Roles = @('Vmf.Operator') }
            Invoke-VmfFacadeSchedule -Principal $principal -StorePath $rp -Wave 'w1' -RunAtUtc ((Get-Date).ToUniversalTime().AddHours(2).ToString('o')) -Note 'window' -WarningAction SilentlyContinue | Out-Null
            $script:asked | Should -Contain 60
        }
        finally { Remove-Item $rp -Recurse -Force }
    }

    It 'a scheduled start and its window check use the wave''s number when they run' {
        $code = Script:MarFunction (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') 'Invoke-VmfFacadeReleaseDueSchedules'
        $code | Should -Not -Match '-Throttle'
        $code | Should -Not -Match '\.throttle'
    }

    It 'the engine container with no share named runs the default, Standard' {
        $code = Get-VmfCodeOnly -Text (Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw) -Language PowerShell
        $code | Should -Match '\$throttle = if \(\$env:VMF_THROTTLE\) \{ \[int\]\$env:VMF_THROTTLE \} else \{ 15 \}'
    }
    It 'a start that names no number reads every machine of the wave by the one rule' {
        $code = Script:MarFunction (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') 'Invoke-VmfFacadeStartEngine'
        $code | Should -Match '\$Throttle = Get-VmfFacadeWaveThrottle -StorePath'
        (Get-Command Invoke-VmfFacadeStartEngine).Parameters.ContainsKey('Throttle') | Should -BeFalse
        $reader = Script:MarFunction (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') 'Get-VmfFacadeWaveThrottle'
        $reader | Should -Match 'Get-VmfWaveThrottle -Entries'
    }
}
