#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SCHEDULE-SCHEMA-1: the schedule document has a schema (hard rule 1).
#
# schedules/<wave>.json says when a wave starts. The service writes it
# (Set-VmfWaveSchedule, and the start record of SCHEDULE-START-ONCE-1 in
# Set-VmfScheduleStartRecord), and the service, the plan continue rule and the
# migration page read it. It crossed a component boundary with no file in
# /schemas, so a change to its shape was checked by nothing.
#
# These tests hold every writer to schemas/wave-schedule.schema.json (what each
# writes is valid, in each state), the schema to the document's real shape (a
# document that breaks a state's rule is refused), and every reader to it (each
# field a reader names is a field the schema declares, and each reader takes a
# valid document of each state).

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'schedschema'
    $script:schema = Join-Path $script:repoRoot 'schemas' 'wave-schedule.schema.json'
    $script:sample = Join-Path $script:repoRoot 'schemas' 'samples' 'wave-schedule.sample.json'

    function Script:WsValid([string]$Text) {
        [bool]($Text | Test-Json -SchemaFile $script:schema -ErrorAction SilentlyContinue)
    }
    function Script:WsRun {
        $rp = Join-Path $script:temp ([guid]::NewGuid().ToString('N').Substring(0, 8))
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'sched-schema' | Out-Null }
        $rp
    }
    function Script:WsText([string]$Run, [string]$Wave = 'wave-1') {
        [System.IO.File]::ReadAllText((Join-Path $Run 'schedules' "$Wave.json"))
    }
    function Script:WsVersion([string]$Text) {
        InModuleScope VmMigrationFactory -Parameters @{ t = $Text } { Get-VmfDocumentVersion -Text $t }
    }
    # A valid document of each state, as the writers write it.
    function Script:WsDoc([string]$State = 'pending') {
        $d = [ordered]@{
            schemaVersion = 1; wave = 'wave-1'
            runAtUtc = '2026-11-03T10:00:00.0000000Z'; scheduledUtc = '2026-11-02T16:00:00.0000000Z'
            scheduledBy = 'operator@example.com'; note = 'change window'; windowMinutes = $null; state = $State
        }
        if ($State -in 'starting', 'started') {
            $d.startId = '0123456789abcdef0123456789abcdef'
            $d.startingUtc = '2026-11-03T10:01:00.0000000Z'
            $d.executions = @()
            $d.startedUtc = $null
        }
        if ($State -eq 'started') {
            $d.executions = @('vmf-engine-abc123')
            $d.startedUtc = '2026-11-03T10:01:05.0000000Z'
        }
        $d
    }
    function Script:WsJson($Doc) { $Doc | ConvertTo-Json -Depth 8 }
    function Script:WsSchemaFields {
        $s = Get-Content $script:schema -Raw | ConvertFrom-Json -AsHashtable
        @($s.properties.Keys)
    }
    # The text of one function in a PowerShell file, comments removed.
    function Script:WsFunctionCode([string]$Path, [string]$Name) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
        if (-not $fn) { throw "No function $Name in $Path" }
        Get-VmfCodeOnly -Text $fn.Extent.Text -Language PowerShell
    }
}

AfterAll { Remove-VmfTestTemp }

Describe 'the schema and its sample' {
    It 'the sample is valid against the schema' {
        Test-Path $script:schema | Should -BeTrue
        WsValid (Get-Content $script:sample -Raw) | Should -BeTrue
    }

    It 'the schema version is the one the service writes' {
        $s = Get-Content $script:schema -Raw | ConvertFrom-Json -AsHashtable
        $s.properties.schemaVersion.const | Should -Be (InModuleScope VmMigrationFactory { Get-VmfWaveScheduleSchemaVersion })
    }

    It 'a valid document of each state passes' -ForEach @(@{ State = 'pending' }, @{ State = 'starting' }, @{ State = 'started' }) {
        WsValid (WsJson (WsDoc $State)) | Should -BeTrue
    }

    It 'a schedule holds no number of machines at once, in any state: the plan says it (OLD-RECORD-SWEEP-ENGINE)' -ForEach @(@{ State = 'pending' }, @{ State = 'starting' }, @{ State = 'started' }) {
        $d = WsDoc $State; $d.throttle = 15
        WsValid (WsJson $d) | Should -BeFalse
    }

    It 'a pending schedule with a time window passes' {
        $d = WsDoc; $d.windowMinutes = 240
        WsValid (WsJson $d) | Should -BeTrue
    }
}

Describe 'the schema refuses a document that breaks the shape' {
    It 'refuses <Why>' -ForEach @(
        @{ Why = 'another schema version'; Edit = { param($d) $d.schemaVersion = 2 } }
        @{ Why = 'a state the service does not write'; Edit = { param($d) $d.state = 'done' } }
        @{ Why = 'a field the schema does not declare'; Edit = { param($d) $d.machinesAtOnce = 4 } }
        @{ Why = 'a document with no wave'; Edit = { param($d) $d.Remove('wave') } }
        @{ Why = 'an empty note'; Edit = { param($d) $d.note = '' } }
        @{ Why = 'an empty name of who scheduled it'; Edit = { param($d) $d.scheduledBy = '' } }
        @{ Why = 'a start time that is not UTC'; Edit = { param($d) $d.runAtUtc = '2026-11-03T10:00:00.0000000+02:00' } }
        @{ Why = 'a start time that is not a date'; Edit = { param($d) $d.runAtUtc = 'tomorrow' } }
        @{ Why = 'a time window of 0 minutes'; Edit = { param($d) $d.windowMinutes = 0 } }
        @{ Why = 'a negative time window'; Edit = { param($d) $d.windowMinutes = -30 } }
        @{ Why = 'a pending schedule with a start id'; Edit = { param($d) $d.startId = '0123456789abcdef0123456789abcdef' } }
        @{ Why = 'a pending schedule with executions'; Edit = { param($d) $d.executions = @('x') } }
    ) {
        $d = WsDoc 'pending'
        & $Edit $d
        WsValid (WsJson $d) | Should -BeFalse
    }

    It 'refuses a <State> record with no <Field>' -ForEach @(
        @{ State = 'starting'; Field = 'startId' }
        @{ State = 'starting'; Field = 'startingUtc' }
        @{ State = 'started'; Field = 'startId' }
        @{ State = 'started'; Field = 'executions' }
        @{ State = 'started'; Field = 'startedUtc' }
    ) {
        $d = WsDoc $State
        $d.Remove($Field)
        WsValid (WsJson $d) | Should -BeFalse
    }

    It 'refuses a start id that is not the 32 characters the service writes' {
        $d = WsDoc 'starting'; $d.startId = 'not-a-guid'
        WsValid (WsJson $d) | Should -BeFalse
    }

    It 'refuses a started record with no time of the start' {
        $d = WsDoc 'started'; $d.startedUtc = $null
        WsValid (WsJson $d) | Should -BeFalse
    }

    It 'refuses a starting record that already has a time of the start' {
        $d = WsDoc 'starting'; $d.startedUtc = '2026-11-03T10:01:05.0000000Z'
        WsValid (WsJson $d) | Should -BeFalse
    }

    It 'refuses a starting record that already names executions' {
        $d = WsDoc 'starting'; $d.executions = @('vmf-engine-abc123')
        WsValid (WsJson $d) | Should -BeFalse
    }
}

Describe 'every writer writes a valid document' {
    BeforeEach { $script:run = WsRun }

    It 'Set-VmfWaveSchedule, with no time window' {
        Set-VmfWaveSchedule -RunPath $script:run -Wave 'wave-1' -RunAtUtc (Get-Date).AddHours(2) -ScheduledBy 'operator@example.com' -Note 'n' | Out-Null
        $text = WsText $script:run
        WsValid $text | Should -BeTrue
        ($text | ConvertFrom-Json).schemaVersion | Should -Be (InModuleScope VmMigrationFactory { Get-VmfWaveScheduleSchemaVersion })
    }

    It 'Set-VmfWaveSchedule, with a time window' {
        Set-VmfWaveSchedule -RunPath $script:run -Wave 'wave-1' -RunAtUtc (Get-Date).AddHours(2) -Note 'n' -WindowMinutes 90 | Out-Null
        $text = WsText $script:run
        WsValid $text | Should -BeTrue
        ($text | ConvertFrom-Json).windowMinutes | Should -Be 90
    }

    It 'Set-VmfWaveSchedule, when the service gives no name of who scheduled it' {
        Set-VmfWaveSchedule -RunPath $script:run -Wave 'wave-1' -RunAtUtc (Get-Date).AddHours(2) -ScheduledBy '' -Note 'n' | Out-Null
        $text = WsText $script:run
        WsValid $text | Should -BeTrue
        ($text | ConvertFrom-Json).scheduledBy | Should -BeExactly 'unknown'
    }

    It 'Set-VmfWaveSchedule refuses a negative time window, and writes nothing' {
        { Set-VmfWaveSchedule -RunPath $script:run -Wave 'wave-1' -RunAtUtc (Get-Date).AddHours(2) -Note 'n' -WindowMinutes -30 } |
            Should -Throw '400:*window*'
        Test-Path (Join-Path $script:run 'schedules' 'wave-1.json') | Should -BeFalse
    }

    It 'the start record: starting, then started with one execution, then with two' {
        Set-VmfWaveSchedule -RunPath $script:run -Wave 'wave-1' -RunAtUtc (Get-Date).AddHours(2) -Note 'n' -WindowMinutes 60 | Out-Null
        $claim = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; v = (WsVersion (WsText $script:run)) } {
            Set-VmfScheduleStartRecord -RunPath $rp -Wave 'wave-1' -Version $v -Starting
        }
        $claim | Should -Not -BeNullOrEmpty
        $starting = WsText $script:run
        WsValid $starting | Should -BeTrue
        ($starting | ConvertFrom-Json).state | Should -BeExactly 'starting'

        $one = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; v = $claim.Version } {
            Set-VmfScheduleStartRecord -RunPath $rp -Wave 'wave-1' -Version $v -Executions @('exec-1')
        }
        $one | Should -Not -BeNullOrEmpty
        $started = WsText $script:run
        WsValid $started | Should -BeTrue
        $doc = $started | ConvertFrom-Json
        $doc.state | Should -BeExactly 'started'
        # One execution is still a list of one.
        $started | Should -Match '"executions":\s*\['
        @($doc.executions) | Should -Be @('exec-1')
    }

    It 'the start record: started with no execution named' {
        Set-VmfWaveSchedule -RunPath $script:run -Wave 'wave-1' -RunAtUtc (Get-Date).AddHours(2) -Note 'n' | Out-Null
        $claim = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; v = (WsVersion (WsText $script:run)) } {
            Set-VmfScheduleStartRecord -RunPath $rp -Wave 'wave-1' -Version $v -Starting
        }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; v = $claim.Version } {
            Set-VmfScheduleStartRecord -RunPath $rp -Wave 'wave-1' -Version $v -Executions @()
        } | Should -Not -BeNullOrEmpty
        WsValid (WsText $script:run) | Should -BeTrue
    }

    It 'the start record written again over a starting record (a start Azure refused)' {
        Set-VmfWaveSchedule -RunPath $script:run -Wave 'wave-1' -RunAtUtc (Get-Date).AddHours(2) -Note 'n' | Out-Null
        $first = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; v = (WsVersion (WsText $script:run)) } {
            Set-VmfScheduleStartRecord -RunPath $rp -Wave 'wave-1' -Version $v -Starting
        }
        $second = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; v = $first.Version } {
            Set-VmfScheduleStartRecord -RunPath $rp -Wave 'wave-1' -Version $v -Starting
        }
        $second.StartId | Should -Not -Be $first.StartId
        WsValid (WsText $script:run) | Should -BeTrue
    }

    It 'SCHEDULE-STARTING-STUCK-1: a starting record put back to pending (a check stopped the start)' {
        Set-VmfWaveSchedule -RunPath $script:run -Wave 'wave-1' -RunAtUtc (Get-Date).AddHours(2) -Note '2026-12-01' -WindowMinutes 45 | Out-Null
        $pending = WsText $script:run
        $claim = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; v = (WsVersion $pending) } {
            Set-VmfScheduleStartRecord -RunPath $rp -Wave 'wave-1' -Version $v -Starting
        }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; v = $claim.Version } {
            Reset-VmfScheduleStartRecord -RunPath $rp -Wave 'wave-1' -Version $v
        } | Should -BeTrue
        $back = WsText $script:run
        WsValid $back | Should -BeTrue
        ($back | ConvertFrom-Json -DateKind String -AsHashtable).Keys | Sort-Object |
            Should -Be @(($pending | ConvertFrom-Json -DateKind String -AsHashtable).Keys | Sort-Object) -Because 'the fields of the pending schedule, and no start on record'
        $was = $pending | ConvertFrom-Json -DateKind String
        $now = $back | ConvertFrom-Json -DateKind String
        foreach ($name in 'schemaVersion', 'wave', 'runAtUtc', 'scheduledUtc', 'scheduledBy', 'note', 'windowMinutes', 'state') {
            $now.$name | Should -BeExactly $was.$name -Because "$name is kept as it was written"
        }
        # The page test (tests/js/schedule-start-shown.test.js) feeds this
        # fixture to the page, which must offer the cancel for it: the fixture
        # has the fields, and the state, the service writes here.
        $fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'wave-schedule-put-back.json') -Raw
        WsValid $fixture | Should -BeTrue
        @(($back | ConvertFrom-Json -AsHashtable).Keys | Sort-Object) | Should -Be @(($fixture | ConvertFrom-Json -AsHashtable).Keys | Sort-Object)
        ($fixture | ConvertFrom-Json).state | Should -BeExactly $now.state
    }

    It 'SCHEDULE-STARTING-STUCK-1: the put back writes nothing over another version, a pending or a started schedule' {
        Set-VmfWaveSchedule -RunPath $script:run -Wave 'wave-1' -RunAtUtc (Get-Date).AddHours(2) -Note 'n' | Out-Null
        $pendingVersion = WsVersion (WsText $script:run)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; v = $pendingVersion } {
            Reset-VmfScheduleStartRecord -RunPath $rp -Wave 'wave-1' -Version $v
        } | Should -BeFalse -Because 'a pending schedule has no start to put back'
        $claim = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; v = $pendingVersion } {
            Set-VmfScheduleStartRecord -RunPath $rp -Wave 'wave-1' -Version $v -Starting
        }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; v = $pendingVersion } {
            Reset-VmfScheduleStartRecord -RunPath $rp -Wave 'wave-1' -Version $v
        } | Should -BeFalse -Because 'the schedule changed after that version'
        (WsText $script:run | ConvertFrom-Json).state | Should -BeExactly 'starting'
        $started = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; v = $claim.Version } {
            Set-VmfScheduleStartRecord -RunPath $rp -Wave 'wave-1' -Version $v -Executions @('exec-1')
        }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; v = $started.Version } {
            Reset-VmfScheduleStartRecord -RunPath $rp -Wave 'wave-1' -Version $v
        } | Should -BeFalse -Because 'a start that was made is never put back'
        (WsText $script:run | ConvertFrom-Json).state | Should -BeExactly 'started'
        Remove-Item (Join-Path $script:run 'schedules' 'wave-1.json')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; v = $started.Version } {
            Reset-VmfScheduleStartRecord -RunPath $rp -Wave 'wave-1' -Version $v
        } | Should -BeFalse -Because 'a schedule that is gone is not written again'
        Test-Path (Join-Path $script:run 'schedules' 'wave-1.json') | Should -BeFalse
    }
}

Describe 'every reader reads a valid document of each state' {
    BeforeEach {
        $script:run = WsRun
        New-Item -ItemType Directory -Path (Join-Path $script:run 'schedules') -Force | Out-Null
        $script:put = { param($State, $Wave = 'wave-1')
            $d = WsDoc $State; $d.wave = $Wave
            $text = WsJson $d
            WsValid $text | Should -BeTrue
            [System.IO.File]::WriteAllText((Join-Path $script:run 'schedules' "$Wave.json"), $text)
        }
    }

    It 'the schedule pass takes each state to its step' {
        & $script:put 'pending' 'w-due'
        & $script:put 'starting' 'w-starting'
        & $script:put 'started' 'w-started'
        $steps = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } {
            Get-VmfScheduleStep -RunPath $rp -AsOf ([datetime]'2026-11-03T11:00:00Z')
        }
        $by = @{}; foreach ($s in $steps) { $by[$s.Wave] = $s.Step }
        $by['w-due'] | Should -BeExactly 'due'
        $by['w-starting'] | Should -BeExactly 'starting'
        $by['w-started'] | Should -BeExactly 'started'
    }

    It 'the grace period reads the start time of a starting record' {
        & $script:put 'starting'
        $s = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } { Get-VmfScheduleStep -RunPath $rp -AsOf ([datetime]'2026-11-03T11:00:00Z') })[0]
        InModuleScope VmMigrationFactory -Parameters @{ sc = $s.Schedule } { Test-VmfScheduleStartFresh -Schedule $sc -NowUtc ([datetime]'2026-11-03T10:02:00Z') } | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ sc = $s.Schedule } { Test-VmfScheduleStartFresh -Schedule $sc -NowUtc ([datetime]'2026-11-03T10:30:00Z') } | Should -BeFalse
    }

    It 'a cancel and a new time are refused for a start on record, and allowed for a pending schedule' {
        & $script:put 'started'
        { Remove-VmfWaveSchedule -RunPath $script:run -Wave 'wave-1' } | Should -Throw '409:*'
        & $script:put 'starting'
        { Set-VmfWaveSchedule -RunPath $script:run -Wave 'wave-1' -RunAtUtc (Get-Date).AddHours(2) -Note 'n' } | Should -Throw '409:*'
        & $script:put 'pending'
        (Remove-VmfWaveSchedule -RunPath $script:run -Wave 'wave-1').WasDueUtc | Should -Not -BeNullOrEmpty
    }

    It 'Get-VmfWaveSchedule names the wave of each state' {
        & $script:put 'pending' 'w-a'
        & $script:put 'started' 'w-b'
        @(Get-VmfWaveSchedule -RunPath $script:run | ForEach-Object { [string]$_.wave } | Sort-Object) | Should -Be @('w-a', 'w-b')
    }
}

Describe 'every field a reader names is a field the schema declares' {
    # A reader that names a field the document does not have reads nothing,
    # with no error. Each pattern finds the fields one reader names.
    It '<Reader> names only declared fields' -ForEach @(
        @{ Reader = 'the migration page'; File = 'src/dashboard/migrations.js'; Function = $null; Patterns = @('\bsched\??\.(\w+)') }
        @{ Reader = 'the schedule pass in the service'; File = 'src/facade/FacadeCore/FacadeCore.psm1'; Function = 'Invoke-VmfFacadeReleaseDueSchedules'; Patterns = @('\$s\.(\w+)') }
        @{ Reader = 'the start record'; File = 'src/VmMigrationFactory/Private/state/ScheduleStart.ps1'; Function = $null
           Patterns = @('\$Schedule\.(\w+)', '\$doc\.(\w+)', "\`$doc\['(\w+)'\]", "Properties\['(\w+)'\]") }
        @{ Reader = 'the wave editor save'; File = 'src/VmMigrationFactory/Public/Set-VmfWavePlan.ps1'; Function = $null; Patterns = @('\$sched\.(\w+)') }
        @{ Reader = 'the cancel'; File = 'src/VmMigrationFactory/Public/Remove-VmfWaveSchedule.ps1'; Function = $null; Patterns = @('\$existing\.(\w+)') }
        @{ Reader = 'the plan continue rule'; File = 'src/VmMigrationFactory/Private/engine/PlanRun.ps1'; Function = $null; Patterns = @('Get-VmfWaveSchedule[^\r\n]*?\$_\.(\w+)') }
    ) {
        $path = Join-Path $script:repoRoot $File
        $code = if ($Function) { WsFunctionCode $path $Function } else { Get-VmfCodeOnly -Path $path }
        $declared = WsSchemaFields
        $named = @(foreach ($pattern in $Patterns) { [regex]::Matches($code, $pattern) | ForEach-Object { $_.Groups[1].Value } }) |
            Where-Object { $_ -ne 'PSObject' } | Sort-Object -Unique
        $named.Count | Should -BeGreaterThan 0 -Because "the patterns must find the fields $Reader reads"
        @($named | Where-Object { $_ -cnotin $declared }) | Should -BeNullOrEmpty -Because "$Reader reads the schedule document"
    }
}
