#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SCHEDULE-START-ONCE-1: a scheduled wave starts once.
#
# The schedule pass started the engine for a due wave and then removed the
# wave's schedule. When the service stopped between the two, or the removal
# threw, the schedule stayed due: while the first run went on the next passes
# left it alone (Test-VmfFacadeEngineRunning), and when that run ended the next
# pass started the wave again.
#
# Now the start is recorded in the schedule before it is made, with an id that
# goes to the engine in the start itself (VMF_SCHEDULE_START), and the record is
# version-checked (PLANVER-2, Write-VmfStoreTextIfVersion). A pass that finds a
# start on record asks Azure for an execution with that id: one there means the
# wave started, so its schedule is removed and nothing starts again; none there
# means the start was not made, so the wave starts as a due wave.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    # Az is not installed in CI, so the service tests mock a stand-in, defined
    # BEFORE the guard (TEST-AZURE-GUARD-1).
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'schedulestartonce'
    $script:operator = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }

    # The engine job as Azure gives it, and a start Azure answers with the
    # code the test gives for each call. Each start Azure accepts is put in
    # Azure's list of executions, with the environment the start sent - as
    # Azure lists it. 'lost' is a start Azure made whose answer did not
    # arrive: listed, and the call throws.
    $script:MockArm = {
        param([string[]]$Codes = @('202'))
        $script:starts = [System.Collections.Generic.List[string]]::new()
        $script:codes = $Codes
        $script:seenAtStart = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
            }
            if ($Method -eq 'POST' -and $Path -match '/start\?') {
                $script:starts.Add($Payload)
                # What the store held for the wave at the moment of the start.
                $file = Join-Path $script:rp 'schedules' 'w1.json'
                $script:seenAtStart.Add($(if (Test-Path $file) { Get-Content $file -Raw | ConvertFrom-Json -DateKind String } else { $null }))
                $code = $script:codes[[math]::Min($script:starts.Count, $script:codes.Count) - 1]
                $name = "exec-$($script:starts.Count)"
                # 'nested': a second pass runs while this start is on its way,
                # before Azure lists it - two passes that overlap.
                if ($code -eq 'nested') {
                    $script:nested = @(& $script:Pass $script:rp)
                    $code = '202'
                }
                if ($code -in '200', '202', 'lost') {
                    $sent = ($Payload | ConvertFrom-Json).containers[0].env
                    $script:Executions = @($script:Executions) + @(@{ name = $name; properties = @{ status = 'Running'; template = @{ containers = @(@{ env = @($sent) }) } } })
                }
                if ($code -eq 'lost') { throw 'The connection was closed before the answer arrived.' }
                if ($code -in '200', '202') {
                    return [pscustomobject]@{ StatusCode = [int]$code; Content = (@{ name = $name; id = 'x' } | ConvertTo-Json) }
                }
                return [pscustomobject]@{ StatusCode = [int]$code; Content = '{"error":{"code":"InternalServerError"}}' }
            }
            [pscustomobject]@{ StatusCode = 200; Content = '{}' }
        }
    }
    # Azure's list of the engine job's executions, read through the module's
    # ARM list. $script:ListCode other than 200 is a list Azure does not give.
    $script:Executions = @()
    $script:ListCode = 200
    $script:MockExecutions = {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { [string]$Path -match '/executions\?' } {
            if ($script:ListCode -ne 200) { return [pscustomobject]@{ StatusCode = $script:ListCode; Content = 'busy' } }
            [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @($script:Executions) } | ConvertTo-Json -Depth 12) }
        }
    }
    $script:EndAll = { foreach ($e in @($script:Executions)) { $e.properties.status = 'Succeeded' } }
    $script:Events = { param($rp) InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) @(Read-VmfEvents -RunPath $rp) } }
    $script:Schedule = { param($rp) $f = Join-Path $rp 'schedules' 'w1.json'; if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json -DateKind String } else { $null } }
    $script:SentId = { param([string]$Payload) [string](@(($Payload | ConvertFrom-Json).containers[0].env | Where-Object { $_.name -eq 'VMF_SCHEDULE_START' }) | Select-Object -First 1).value }
    # The start record as a pass wrote it some minutes ago: its own field, in
    # the form the service writes it ('o', UTC).
    $script:AgeRecord = { param($rp, [double]$Minutes)
        $file = Join-Path $rp 'schedules' 'w1.json'
        $doc = Get-Content $file -Raw | ConvertFrom-Json -DateKind String -AsHashtable
        $doc['startingUtc'] = (Get-Date).ToUniversalTime().AddMinutes(-$Minutes).ToString('o')
        [System.IO.File]::WriteAllText($file, ($doc | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
    }
    $script:Pass = { param($rp) @(Invoke-VmfFacadeReleaseDueSchedules -StorePath $rp -RunId 'sso' -AsOf (Get-Date).ToUniversalTime().AddHours(1)) }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\Invoke-AzRestMethod' -ErrorAction SilentlyContinue
    Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
}

Describe 'SCHEDULE-START-ONCE-1: a scheduled wave starts once' {
    BeforeEach {
        $script:root = Join-Path $script:temp "sso-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $env:VMF_STORE_PATH = $script:root
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:rp = Join-Path $script:root 'sso'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            param($rp)
            Initialize-VmfRun -RunPath $rp -RunId 'sso' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = 9; runId = 'sso'
                entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/a'
                                        wave = 'w1'; path = 'A'; policy = [ordered]@{ requireApproval = $false; throttle = 5 } }) })
        }
        Invoke-VmfFacadeSchedule -Principal $script:operator -StorePath $script:rp -Wave 'w1' `
            -RunAtUtc ((Get-Date).AddMinutes(30).ToString('o')) -Note 'tonight' | Out-Null
        $script:Executions = @()
        $script:ListCode = 200
        & $script:MockExecutions
    }
    AfterEach { Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }

    It 'records the start in the schedule BEFORE the start, and sends the same id to the engine' {
        & $script:MockArm
        $r = & $script:Pass $script:rp
        @($r.Wave) | Should -Be @('w1')
        $script:starts.Count | Should -Be 1
        $seen = $script:seenAtStart[0]
        $seen.state | Should -BeExactly 'starting' -Because 'a stop after the start must find the start on record'
        [string]$seen.startId | Should -Match '^[0-9a-f]{32}$'
        (& $script:SentId $script:starts[0]) | Should -BeExactly ([string]$seen.startId) -Because 'the id is how the next pass finds this start in Azure'
        $seen.runAtUtc | Should -BeOfType [string]
        # SCHEDULE-WAVE-VERSION-1: the engine run of the start removes the
        # start time once its read of the wave is the one the pass judged.
        $doc = & $script:Schedule $script:rp
        $doc.state | Should -BeExactly 'started' -Because 'the start is on record until the engine run removes it'
        @($doc.executions) | Should -Be @('exec-1')
        $said = @(& $script:Events $script:rp | Where-Object { $_.step -eq 'schedule' } | ForEach-Object { [string]$_.detail })
        ($said -join "`n") | Should -BeLike '*The service started the engine for wave w1 at its scheduled time (execution exec-1).*'
    }

    It 'a removal that fails after the start is said as a started wave, and no later pass starts it again' {
        & $script:MockArm
        $script:removeFails = $true
        Mock -ModuleName VmMigrationFactory Remove-VmfStoreItemIfVersion -ParameterFilter { $RelPath -like 'schedules/*' } {
            if ($script:removeFails) { throw 'The store did not answer.' }
            $false
        }
        $r = & $script:Pass $script:rp
        @($r.Wave) | Should -Be @('w1') -Because 'the wave was released; only its start time stays'
        $doc = & $script:Schedule $script:rp
        $doc.state | Should -BeExactly 'started'
        @($doc.executions) | Should -Be @('exec-1')
        # The first run goes on: the next pass starts nothing, and leaves the
        # start time to that run (SCHEDULE-WAVE-VERSION-1).
        & $script:Pass $script:rp | Should -BeNullOrEmpty
        $script:starts.Count | Should -Be 1
        # The run ended without removing it (the engine stopped before its
        # check), and the store does not answer: said, and nothing starts.
        & $script:EndAll
        & $script:Pass $script:rp | Should -BeNullOrEmpty
        $script:starts.Count | Should -Be 1
        (& $script:Schedule $script:rp).state | Should -BeExactly 'started'
        $events = @(& $script:Events $script:rp | Where-Object { $_.step -eq 'schedule' })
        @($events | Where-Object { $_.outcome -eq 'fail' }).Count | Should -Be 0
        $warn = @($events | Where-Object { $_.outcome -eq 'warn' } | ForEach-Object { [string]$_.detail }) -join "`n"
        $warn | Should -BeLike '*Wave w1 started at its scheduled time (execution exec-1), but the service could not remove its start time: The store did not answer.*'
        $warn | Should -BeLike '*does not start the wave again*'
        # The start time goes once the store answers.
        $script:removeFails = $false
        $script:removedVersion = $null
        Mock -ModuleName VmMigrationFactory Remove-VmfStoreItemIfVersion -ParameterFilter { $RelPath -like 'schedules/*' } {
            # The store answers again: the document goes, on the file backend.
            $script:removedVersion = $ExpectedVersion
            Remove-Item -LiteralPath (Join-Path $RunPath $RelPath) -Force
            $true
        }
        & $script:Pass $script:rp | Should -BeNullOrEmpty
        $script:starts.Count | Should -Be 1 -Because 'the schedule had its start on record'
        (& $script:Schedule $script:rp) | Should -BeNullOrEmpty
        $script:removedVersion | Should -Match '^[0-9a-f]{64}$' -Because 'only the document the pass judged is removed'
    }

    It 'a stop between the start and its record: the next pass finds the start in Azure and starts nothing' {
        # The start Azure made, and its answer did not arrive - the same store
        # as a pass the host stopped right after the start.
        & $script:MockArm -Codes @('lost')
        { & $script:Pass $script:rp } | Should -Throw '*connection was closed*'
        $doc = & $script:Schedule $script:rp
        $doc.state | Should -BeExactly 'starting'
        & $script:EndAll
        & $script:Pass $script:rp | Should -BeNullOrEmpty
        $script:starts.Count | Should -Be 1 -Because 'Azure lists an execution with the id of the start on record'
        (& $script:Schedule $script:rp) | Should -BeNullOrEmpty
        $said = @(& $script:Events $script:rp | Where-Object { $_.step -eq 'schedule' } | ForEach-Object { [string]$_.detail }) -join "`n"
        $said | Should -BeLike '*Wave w1 started at its scheduled time (execution exec-1)*did not start the wave again*'
    }

    It 'a stop after the start whose record and removal both fail: the next pass finds the start in Azure' {
        & $script:MockArm
        Mock -ModuleName VmMigrationFactory Write-VmfStoreTextIfVersion -ParameterFilter { $RelPath -like 'schedules/*' -and $Content -match '"started"' } { throw 'The store did not answer.' }
        Mock -ModuleName VmMigrationFactory Remove-VmfStoreItemIfVersion -ParameterFilter { $RelPath -like 'schedules/*' } { throw 'The store did not answer.' }
        $r = & $script:Pass $script:rp
        @($r.Wave) | Should -Be @('w1')
        (& $script:Schedule $script:rp).state | Should -BeExactly 'starting'
        & $script:EndAll
        & $script:Pass $script:rp | Should -BeNullOrEmpty
        $script:starts.Count | Should -Be 1
    }

    It 'a start on record that Azure does not list was not made: the next pass starts the wave once, with a new id' {
        & $script:MockArm -Codes @('500', '202')
        # An earlier scheduled start of the same wave, which ended: another id.
        $script:Executions = @(@{ name = 'exec-earlier'; properties = @{ status = 'Succeeded'; template = @{ containers = @(@{ env = @(
            @{ name = 'VMF_OPERATION'; value = 'wave' }, @{ name = 'VMF_RUN_ID'; value = 'sso' }, @{ name = 'VMF_WAVE'; value = 'w1' },
            @{ name = 'VMF_SCHEDULE_START'; value = ('e' * 32) }) }) } } })
        { & $script:Pass $script:rp } | Should -Throw '*Engine start failed*'
        $first = & $script:Schedule $script:rp
        $first.state | Should -BeExactly 'starting'
        # A fresh record may belong to a pass that still starts the engine: left alone.
        & $script:Pass $script:rp | Should -BeNullOrEmpty
        $script:starts.Count | Should -Be 1
        (& $script:Schedule $script:rp).startId | Should -BeExactly ([string]$first.startId)
        # Older than the grace period, with nothing listed: the start was not made.
        & $script:AgeRecord $script:rp 11
        $r = & $script:Pass $script:rp
        @($r.Wave) | Should -Be @('w1')
        $script:starts.Count | Should -Be 2
        (& $script:SentId $script:starts[1]) | Should -Not -BeExactly ([string]$first.startId) -Because 'each start has its own id'
        (& $script:Schedule $script:rp).state | Should -BeExactly 'started' -Because 'the engine run of the start removes the start time'
        @((& $script:Schedule $script:rp).executions) | Should -Be @('exec-2')
    }

    It 'two passes that overlap start the wave once' {
        # Pass B reads the start record pass A wrote a moment ago, and Azure
        # does not list A's start yet.
        & $script:MockArm -Codes @('nested', '202')
        $script:nested = $null
        $r = & $script:Pass $script:rp
        @($r.Wave) | Should -Be @('w1')
        @($script:nested | Where-Object { $_ }).Count | Should -Be 0 -Because 'the second pass left the fresh start record alone'
        $script:starts.Count | Should -Be 1
        (& $script:Schedule $script:rp).state | Should -BeExactly 'started'
    }

    It 'the grace period ends at 10 minutes, read from the record as the service wrote it' {
        $now = [datetime]::new(2026, 11, 3, 12, 0, 0, [System.DateTimeKind]::Utc)
        InModuleScope VmMigrationFactory -Parameters @{ n = $now } {
            param($n)
            $rec = { param([double]$s) [pscustomobject]@{ state = 'starting'; startingUtc = $n.AddSeconds(-$s).ToString('o') } }
            Test-VmfScheduleStartFresh -Schedule (& $rec 599) -NowUtc $n | Should -BeTrue
            Test-VmfScheduleStartFresh -Schedule (& $rec 600) -NowUtc $n | Should -BeFalse
            Test-VmfScheduleStartFresh -Schedule (& $rec 0) -NowUtc $n | Should -BeTrue
            # As ConvertFrom-Json reads it without -DateKind String: a date value.
            Test-VmfScheduleStartFresh -Schedule ('{"startingUtc":"' + $n.AddSeconds(-30).ToString('o') + '"}' | ConvertFrom-Json) -NowUtc $n | Should -BeTrue
            Test-VmfScheduleStartFresh -Schedule ('{"startingUtc":"' + $n.AddSeconds(-900).ToString('o') + '"}' | ConvertFrom-Json) -NowUtc $n | Should -BeFalse
            # A date value is taken as the instant it is, to the millisecond -
            # not through its text, which drops the part of a second.
            Test-VmfScheduleStartFresh -Schedule ([pscustomobject]@{ startingUtc = $n.ToLocalTime().AddMilliseconds(-599500) }) -NowUtc $n | Should -BeTrue
            # A record with no time, or one that cannot be read, is old: the wave is not held for ever.
            Test-VmfScheduleStartFresh -Schedule ([pscustomobject]@{ state = 'starting' }) -NowUtc $n | Should -BeFalse
            Test-VmfScheduleStartFresh -Schedule ([pscustomobject]@{ startingUtc = 'not a time' }) -NowUtc $n | Should -BeFalse
        }
    }

    It 'a start on record that cannot be checked in Azure starts nothing' {
        & $script:MockArm -Codes @('500', '202')
        { & $script:Pass $script:rp } | Should -Throw '*Engine start failed*'
        $script:ListCode = 503
        { & $script:Pass $script:rp } | Should -Throw '*Could not list engine executions: HTTP 503*'
        $script:starts.Count | Should -Be 1
        (& $script:Schedule $script:rp).state | Should -BeExactly 'starting'
    }

    It 'a schedule that changed after the pass read it does not start' {
        & $script:MockArm
        Mock -ModuleName VmMigrationFactory Write-VmfStoreTextIfVersion -ParameterFilter { $RelPath -like 'schedules/*' } { $false }
        & $script:Pass $script:rp | Should -BeNullOrEmpty
        $script:starts.Count | Should -Be 0
        (& $script:Schedule $script:rp).state | Should -BeExactly 'pending'
        $warn = @(& $script:Events $script:rp | Where-Object { $_.step -eq 'schedule' -and $_.outcome -eq 'warn' } | ForEach-Object { [string]$_.detail }) -join "`n"
        $warn | Should -BeLike '*Wave w1 was due to start, but its schedule changed at the same time*'
    }

    It 'a scheduled start the service is starting, or started, cannot be cancelled or set again' {
        & $script:MockArm -Codes @('500')
        { & $script:Pass $script:rp } | Should -Throw '*Engine start failed*'
        { Invoke-VmfFacadeSchedule -Principal $script:operator -StorePath $script:rp -Wave 'w1' -Cancel -Note 'moved' } |
            Should -Throw '409: The service started wave w1 at its scheduled time, or is starting it now*'
        { Invoke-VmfFacadeSchedule -Principal $script:operator -StorePath $script:rp -Wave 'w1' `
            -RunAtUtc ((Get-Date).AddHours(3).ToString('o')) -Note 'later' } | Should -Throw '409: The service started wave w1*'
        (& $script:Schedule $script:rp).state | Should -BeExactly 'starting'
    }

    It 'a schedule with its start on record is not due' {
        & $script:MockArm -Codes @('500')
        { & $script:Pass $script:rp } | Should -Throw '*Engine start failed*'
        $steps = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) @(Get-VmfScheduleStep -RunPath $rp -AsOf (Get-Date).ToUniversalTime().AddHours(1)) }
        @($steps.Step) | Should -Be @('starting')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            param($rp) Test-VmfScheduleDue -Schedule (Read-VmfStoreJson -RunPath $rp -RelPath 'schedules/w1.json') -AsOf (Get-Date).ToUniversalTime().AddHours(1)
        } | Should -BeFalse
        @(Get-VmfWaveSchedule -RunPath $script:rp).Count | Should -Be 1
    }

    It 'the start record keeps every text of the schedule as it was written' {
        # ConvertFrom-Json turns a text that looks like a date into a date
        # value, and ConvertTo-Json then writes it in another form.
        Invoke-VmfFacadeSchedule -Principal $script:operator -StorePath $script:rp -Wave 'w1' `
            -RunAtUtc ((Get-Date).AddMinutes(30).ToString('o')) -Note '2026-12-01' | Out-Null
        $before = & $script:Schedule $script:rp
        & $script:MockArm -Codes @('500')
        { & $script:Pass $script:rp } | Should -Throw '*Engine start failed*'
        $after = & $script:Schedule $script:rp
        $after.state | Should -BeExactly 'starting'
        $after.note | Should -BeExactly '2026-12-01'
        $after.runAtUtc | Should -BeExactly $before.runAtUtc
        $after.scheduledUtc | Should -BeExactly $before.scheduledUtc
    }
    It 'a pending schedule is cancelled as before' {
        Invoke-VmfFacadeSchedule -Principal $script:operator -StorePath $script:rp -Wave 'w1' -Cancel -Note 'moved' | Out-Null
        (& $script:Schedule $script:rp) | Should -BeNullOrEmpty
    }

    # SCHEDULE-STARTING-STUCK-1: a start record older than the grace period,
    # with no execution in Azure, goes through the start checks again. When a
    # check stops it, the schedule goes back to what a scheduled start whose
    # check fails on its first try leaves: pending, with the reason in the
    # activity. Before, it stayed 'starting': the page said "The wave is
    # starting.", the service refused a cancel, and the activity told the
    # operator to cancel.
    Context 'SCHEDULE-STARTING-STUCK-1: a start record a check stops goes back to pending' {
        BeforeEach {
            # A start Azure refused, older than the grace period: not made.
            & $script:MockArm -Codes @('500', '202')
            { & $script:Pass $script:rp } | Should -Throw '*Engine start failed*'
            $script:firstRecord = & $script:Schedule $script:rp
            $script:firstRecord.state | Should -BeExactly 'starting'
            & $script:AgeRecord $script:rp 11
            $script:Said = { @(& $script:Events $script:rp | Where-Object { $_.step -eq 'schedule' -and $_.outcome -eq 'warn' } | ForEach-Object { [string]$_.detail }) -join "`n" }
            # The schedule as a page reads it: no start on record, so a cancel
            # is offered and accepted.
            $script:AssertPending = {
                $doc = & $script:Schedule $script:rp
                $doc.state | Should -BeExactly 'pending' -Because 'a stopped start must offer the cancel again'
                foreach ($name in 'startId', 'startingUtc', 'executions', 'startedUtc') {
                    $doc.PSObject.Properties.Name | Should -Not -Contain $name -Because 'a pending schedule has no start on record (schemas/wave-schedule)'
                }
                $doc.note | Should -BeExactly 'tonight'
                $doc.runAtUtc | Should -BeExactly $script:firstRecord.runAtUtc
                $doc.scheduledUtc | Should -BeExactly $script:firstRecord.scheduledUtc
                $doc.scheduledBy | Should -BeExactly $script:firstRecord.scheduledBy
                InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfScheduleStartRefusal -Schedule $d -Wave 'w1' } | Should -BeNullOrEmpty
            }
        }

        It 'a wave that is not approved: pending, the reason said, and a cancel is accepted' {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
                param($rp)
                $plan = Read-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24
                $plan.entries[0].policy.requireApproval = $true
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document $plan
            }
            & $script:Pass $script:rp | Should -BeNullOrEmpty
            $script:starts.Count | Should -Be 1 -Because 'the check stops the start'
            & $script:AssertPending
            (& $script:Said) | Should -BeLike '*wave w1 was due to start but has not been approved - it stays scheduled*'
            Invoke-VmfFacadeSchedule -Principal $script:operator -StorePath $script:rp -Wave 'w1' -Cancel -Note 'moved' | Out-Null
            (& $script:Schedule $script:rp) | Should -BeNullOrEmpty
        }

        It 'a wave that changed after the sign-off: pending, so the cancel the activity names is accepted' {
            Mock -ModuleName VmMigrationFactory Get-VmfUnattendedStartRefusal { 'changed after the plan sign-off' }
            & $script:Pass $script:rp | Should -BeNullOrEmpty
            $script:starts.Count | Should -Be 1
            & $script:AssertPending
            (& $script:Said) | Should -BeLike '*select Cancel the scheduled start, then select Start this wave*'
            Invoke-VmfFacadeSchedule -Principal $script:operator -StorePath $script:rp -Wave 'w1' -Cancel -Note 'moved' | Out-Null
            (& $script:Schedule $script:rp) | Should -BeNullOrEmpty
        }

        It 'a wave that does not fit its window: pending, the reason said' {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
                param($rp)
                $s = Read-VmfStoreText -RunPath $rp -RelPath 'schedules/w1.json' | ConvertFrom-Json -Depth 8 -DateKind String -AsHashtable
                $s['windowMinutes'] = 30
                Write-VmfStoreText -RunPath $rp -RelPath 'schedules/w1.json' -Content ($s | ConvertTo-Json -Depth 8)
            }
            Mock -ModuleName FacadeCore Test-VmfWaveWindow { [pscustomobject]@{ Fits = $false; Reason = 'the estimate is 90 minutes' } }
            & $script:Pass $script:rp | Should -BeNullOrEmpty
            $script:starts.Count | Should -Be 1
            & $script:AssertPending
            (& $script:Schedule $script:rp).windowMinutes | Should -Be 30
            (& $script:Said) | Should -BeLike '*wave w1 was due to start but will not fit its window: the estimate is 90 minutes*'
        }

        It 'a run of the wave goes on: the record stays starting with its start id, and the wave starts when that run ends' {
            # That run may be THIS start, which Azure lists later than the
            # grace period. A put-back would drop the start id, and the
            # pending schedule would start the wave a second time after it.
            $script:engineRuns = $true
            Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $script:engineRuns }
            & $script:Pass $script:rp | Should -BeNullOrEmpty
            $script:starts.Count | Should -Be 1
            $doc = & $script:Schedule $script:rp
            $doc.state | Should -BeExactly 'starting' -Because 'the run that goes on may be this start'
            [string]$doc.startId | Should -BeExactly ([string]$script:firstRecord.startId) -Because 'the next pass asks Azure for this start by its id'
            # The run ended, and Azure lists no execution of this start: the
            # checks run again, as before.
            $script:engineRuns = $false
            @((& $script:Pass $script:rp).Wave) | Should -Be @('w1')
            $script:starts.Count | Should -Be 2
            (& $script:Schedule $script:rp).state | Should -BeExactly 'started'
        }

        It 'a schedule that changed at the same time is not written over' {
            Mock -ModuleName VmMigrationFactory Get-VmfUnattendedStartRefusal { 'changed after the plan sign-off' }
            Mock -ModuleName VmMigrationFactory Write-VmfStoreTextIfVersion -ParameterFilter { $RelPath -like 'schedules/*' } { $false }
            & $script:Pass $script:rp | Should -BeNullOrEmpty
            (& $script:Schedule $script:rp).state | Should -BeExactly 'starting'
            (& $script:Said) | Should -BeLike '*Wave w1 was due to start, but its schedule changed at the same time*'
            (& $script:Said) | Should -Not -BeLike '*select Cancel the scheduled start*' -Because 'the cancel is not offered for a record still starting'
        }

        It 'kill-resume: a stop before the write leaves the record, and the next pass puts it back' {
            Mock -ModuleName VmMigrationFactory Get-VmfUnattendedStartRefusal { 'changed after the plan sign-off' }
            $script:storeDown = $true
            Mock -ModuleName VmMigrationFactory Write-VmfStoreTextIfVersion -ParameterFilter { $RelPath -like 'schedules/*' -and $script:storeDown } { throw 'The store did not answer.' }
            & $script:Pass $script:rp | Should -BeNullOrEmpty -Because 'one wave the store fails for does not stop the pass'
            (& $script:Schedule $script:rp).state | Should -BeExactly 'starting'
            (& $script:Said) | Should -BeLike '*Wave w1 was due to start, but the service could not put its schedule back: The store did not answer.*next pass*'
            $script:storeDown = $false
            & $script:Pass $script:rp | Should -BeNullOrEmpty
            $script:starts.Count | Should -Be 1
            & $script:AssertPending
        }

        It 'kill-resume: a stop after the write, before the activity line, is safe to run again' {
            Mock -ModuleName VmMigrationFactory Get-VmfUnattendedStartRefusal { 'changed after the plan sign-off' }
            $script:lineDown = $true
            Mock -ModuleName VmMigrationFactory Write-VmfStepLine -ParameterFilter { $Step -eq 'schedule' -and $script:lineDown } { throw 'The host stopped the pass.' }
            try { & $script:Pass $script:rp | Out-Null } catch { $null = $_ }
            & $script:AssertPending
            $script:lineDown = $false
            & $script:Pass $script:rp | Should -BeNullOrEmpty
            $script:starts.Count | Should -Be 1 -Because 'a pending wave whose check fails does not start'
            & $script:AssertPending
            (& $script:Said) | Should -BeLike '*select Cancel the scheduled start, then select Start this wave*'
        }

        It 'a wave whose checks pass starts once, as before' {
            $r = & $script:Pass $script:rp
            @($r.Wave) | Should -Be @('w1')
            $script:starts.Count | Should -Be 2
            (& $script:Schedule $script:rp).state | Should -BeExactly 'started'
        }
    }
}
