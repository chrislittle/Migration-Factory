#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SCHEDULE-WAVE-VERSION-1: a scheduled start sends the version of the wave its
# checks judged, and a wave that changed before the engine read it does not
# start and stays scheduled.
#
# The schedule pass judged the approval gate and the unattended-start rule on
# the plan text it read, then started the engine with no wave version. The
# engine judged its OWN later read: a wave set not to need a sign-off that
# changed in that time started at its scheduled time with no approver looking.
# The next wave of a signed-off plan already sends the version
# (Invoke-VmfFacadeContinuePlan, WAVE-APPROVE-1), and Start-VmfWave refuses a
# start whose own read of the wave differs. The schedule pass now sends it too.
#
# Sending it alone was not enough: the pass removed the schedule right after
# the start, so a start the engine refused never ran, and the engine's words
# ("checks the wave again") were not true. Now the schedule stays 'started'
# while the start's engine run goes on. The engine removes it once its read of
# the wave is the one the pass judged, and puts it back to 'pending'
# (Reset-VmfScheduleStartRecord) when it is not - the engine run that refuses
# is the only one that puts it back. The service never removes or puts back a
# schedule while an engine run of its start goes on.

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
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'schedwavever'
    $script:operator = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    $script:who = @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }
    $script:schema = Join-Path $script:repoRoot 'schemas' 'wave-schedule.schema.json'

    # The engine job as Azure gives it, and a start Azure answers with the
    # code the test gives for each call. Each start Azure accepts is put in
    # Azure's list of executions with the environment the start sent, status
    # Running. 'lost': a start Azure made whose answer did not arrive.
    $script:MockArm = {
        param([string[]]$Codes = @('202'))
        $script:starts = [System.Collections.Generic.List[string]]::new()
        $script:codes = $Codes
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
            }
            if ($Method -eq 'POST' -and $Path -match '/start\?') {
                $script:starts.Add($Payload)
                $code = $script:codes[[math]::Min($script:starts.Count, $script:codes.Count) - 1]
                $name = "exec-$($script:starts.Count)"
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
    $script:Executions = @()
    $script:MockExecutions = {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { [string]$Path -match '/executions\?' } {
            # $script:ListFailsAfter: the listings Azure gives before it gives
            # none (-1: every listing is given).
            $script:Listings++
            if ($script:ListFailsAfter -ge 0 -and $script:Listings -gt $script:ListFailsAfter) { return [pscustomobject]@{ StatusCode = 503; Content = 'busy' } }
            [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @($script:Executions) } | ConvertTo-Json -Depth 12) }
        }
    }
    $script:EndAll = { foreach ($e in @($script:Executions)) { $e.properties.status = 'Failed' } }
    $script:Events = { param($rp) InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) @(Read-VmfEvents -RunPath $rp) } }
    $script:Said = { param([string]$Outcome) @(& $script:Events $script:rp | Where-Object { $_.step -eq 'schedule' -and (-not $Outcome -or $_.outcome -eq $Outcome) } | ForEach-Object { [string]$_.detail }) -join "`n" }
    $script:ScheduleFile = { Join-Path $script:rp 'schedules' 'w1.json' }
    $script:Schedule = { $f = & $script:ScheduleFile; if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json -DateKind String } else { $null } }
    $script:Env = { param([string]$Payload, [string]$Name) [string](@(($Payload | ConvertFrom-Json).containers[0].env | Where-Object { $_.name -eq $Name }) | Select-Object -First 1).value }
    $script:PlanText = { [System.IO.File]::ReadAllText((Join-Path $script:rp 'plan.json')) }
    $script:WaveVersionOf = { param([string]$Text) InModuleScope VmMigrationFactory -Parameters @{ t = $Text } { param($t) Get-VmfWaveVersion -PlanText $t -Wave 'w1' } }
    # A person changes the wave: the number of machines at once, which is in
    # the wave version (Get-VmfWaveVersion).
    $script:EditWave = { param([int]$Throttle = 6)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; t = $Throttle } {
            param($rp, $t)
            $plan = Read-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24
            $plan.entries[0].policy.throttle = $t
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document $plan
        }
    }
    $script:Approve = { Approve-VmfWave -RunPath $script:rp -PlanPath (Join-Path $script:rp 'plan.json') -Wave 'w1' -Note 'approved' -OnBehalfOf $script:who | Out-Null }
    # The engine container of one start: the wave operation, with what the
    # start sent it (docker/entrypoint.ps1). Returns what it threw.
    $script:Engine = { param([string]$Payload)
        $params = @{ PlanPath = (Join-Path $script:rp 'plan.json'); Wave = 'w1'; RunPath = $script:rp }
        $v = & $script:Env $Payload 'VMF_WAVE_VERSION'
        $sid = & $script:Env $Payload 'VMF_SCHEDULE_START'
        if ($v) { $params.WaveVersion = $v }
        if ($sid) { $params.ScheduleStartId = $sid }
        try { Start-VmfWave @params | Out-Null; '' } catch { $_.Exception.Message }
    }
    $script:Pass = { @(Invoke-VmfFacadeReleaseDueSchedules -StorePath $script:rp -RunId 'swv' -AsOf (Get-Date).ToUniversalTime().AddHours(1)) }
    $script:AssertPending = { param($First)
        $doc = & $script:Schedule
        $doc.state | Should -BeExactly 'pending' -Because 'a start the engine refused leaves the wave scheduled'
        foreach ($name in 'startId', 'startingUtc', 'executions', 'startedUtc') {
            $doc.PSObject.Properties.Name | Should -Not -Contain $name -Because 'a pending schedule has no start on record (schemas/wave-schedule)'
        }
        $doc.note | Should -BeExactly 'tonight'
        $doc.runAtUtc | Should -BeExactly $First.runAtUtc
        $doc.scheduledUtc | Should -BeExactly $First.scheduledUtc
        $doc.scheduledBy | Should -BeExactly $First.scheduledBy
        [bool]([System.IO.File]::ReadAllText((& $script:ScheduleFile)) | Test-Json -SchemaFile $script:schema -ErrorAction SilentlyContinue) | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfScheduleStartRefusal -Schedule $d -Wave 'w1' } | Should -BeNullOrEmpty -Because 'the page offers the cancel, and the service accepts it'
    }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\Invoke-AzRestMethod' -ErrorAction SilentlyContinue
    Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
}

Describe 'SCHEDULE-WAVE-VERSION-1: a scheduled start sends the wave version its checks judged' {
    BeforeEach {
        $script:root = Join-Path $script:temp "swv-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $env:VMF_STORE_PATH = $script:root
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:rp = Join-Path $script:root 'swv'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            param($rp)
            Initialize-VmfRun -RunPath $rp -RunId 'swv' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = 9; runId = 'swv'
                entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/a'
                                        wave = 'w1'; path = 'A'; policy = [ordered]@{ requireApproval = $true; throttle = 5 } }) })
        }
        & $script:Approve
        Invoke-VmfFacadeSchedule -Principal $script:operator -StorePath $script:rp -Wave 'w1' `
            -RunAtUtc ((Get-Date).AddMinutes(30).ToString('o')) -Note 'tonight' | Out-Null
        $script:first = & $script:Schedule
        $script:Executions = @()
        $script:Listings = 0
        $script:ListFailsAfter = -1
        & $script:MockExecutions
    }
    AfterEach { Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }

    It 'sends the version of the wave in the plan text that the checks judged' {
        & $script:MockArm
        $judged = & $script:PlanText
        @((& $script:Pass).Wave) | Should -Be @('w1')
        $script:starts.Count | Should -Be 1
        (& $script:Env $script:starts[0] 'VMF_WAVE_VERSION') | Should -BeExactly (& $script:WaveVersionOf $judged) -Because 'the engine compares its own read with the wave the checks passed'
        (& $script:Env $script:starts[0] 'VMF_WAVE_VERSION') | Should -Match '^[0-9a-f]{64}$'
    }

    It 'the gates and the version are read from the same plan text' {
        # A change that lands after the gates read the plan, and before the
        # version is taken, must not get a version of its own: the start must
        # carry the version of the text the gates judged.
        & $script:MockArm
        $judged = & $script:PlanText
        Mock -ModuleName VmMigrationFactory Get-VmfUnattendedStartRefusal {
            & $script:EditWave 9
            $null
        }
        @((& $script:Pass).Wave) | Should -Be @('w1')
        (& $script:Env $script:starts[0] 'VMF_WAVE_VERSION') | Should -BeExactly (& $script:WaveVersionOf $judged)
        (& $script:Engine $script:starts[0]) | Should -BeLike 'Wave w1 changed after the service checked it for its scheduled start, so it did not start.*'
    }

    It 'the schedule stays while the start runs, and the engine removes it when its read of the wave is the one judged' {
        & $script:MockArm
        & $script:Pass | Out-Null
        $doc = & $script:Schedule
        $doc.state | Should -BeExactly 'started' -Because 'the engine has not read the wave yet'
        @($doc.executions) | Should -Be @('exec-1')
        (& $script:Said 'info') | Should -BeLike '*The service started the engine for wave w1 at its scheduled time (execution exec-1).*'
        # Another pass while the engine run goes on: nothing is removed,
        # nothing is put back, and nothing starts.
        & $script:Pass | Should -BeNullOrEmpty
        (& $script:Schedule).state | Should -BeExactly 'started'
        $script:starts.Count | Should -Be 1
        # The engine reads the same wave: the start goes on (to its next gate,
        # here the infrastructure question nobody accepted), and the schedule goes.
        $why = & $script:Engine $script:starts[0]
        $why | Should -Not -BeLike '*changed after the service checked it*'
        (& $script:Schedule) | Should -BeNullOrEmpty -Because 'the engine passed its check of the wave, so the start time goes'
        (& $script:Said 'info') | Should -BeLike '*Wave w1 started at its scheduled time, and the engine removed its start time.*'
    }

    It 'a wave changed between the checks and the engine read does not start, stays scheduled, and starts on a later pass when approved' {
        & $script:MockArm
        & $script:Pass | Out-Null
        $sent = & $script:Env $script:starts[0] 'VMF_WAVE_VERSION'
        & $script:EditWave
        $why = & $script:Engine $script:starts[0]
        $why | Should -BeExactly 'Wave w1 changed after the service checked it for its scheduled start, so it did not start. It stays scheduled, and the service checks it again on its next pass.'
        & $script:AssertPending $script:first
        # The engine run ended. The next pass judges the changed wave: its
        # approval is for the wave as it was, so it waits.
        & $script:EndAll
        & $script:Pass | Should -BeNullOrEmpty
        $script:starts.Count | Should -Be 1 -Because 'the changed wave is not approved'
        (& $script:Schedule).state | Should -BeExactly 'pending'
        (& $script:Said 'warn') | Should -BeLike '*wave w1 was due to start but has not been approved - it stays scheduled*'
        # Approved again: the next pass starts it, with the version of the wave as it is now.
        & $script:Approve
        @((& $script:Pass).Wave) | Should -Be @('w1')
        $script:starts.Count | Should -Be 2
        $now = & $script:Env $script:starts[1] 'VMF_WAVE_VERSION'
        $now | Should -BeExactly (& $script:WaveVersionOf (& $script:PlanText))
        $now | Should -Not -BeExactly $sent
        (& $script:Env $script:starts[1] 'VMF_SCHEDULE_START') | Should -Not -BeExactly (& $script:Env $script:starts[0] 'VMF_SCHEDULE_START') -Because 'each start has its own id'
        (& $script:Engine $script:starts[1]) | Should -Not -BeLike '*changed after the service checked it*'
        (& $script:Schedule) | Should -BeNullOrEmpty
    }

    It 'a wave set not to need a sign-off that changed after the plan sign-off stays scheduled after the refusal' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            param($rp)
            $plan = Read-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24
            $plan.entries[0].policy.requireApproval = $false
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document $plan
        }
        & $script:MockArm
        & $script:Pass | Out-Null
        & $script:EditWave
        (& $script:Engine $script:starts[0]) | Should -BeLike '*It stays scheduled*'
        & $script:AssertPending $script:first
        & $script:EndAll
        # The unattended-start rule judges the wave as it is now.
        Mock -ModuleName VmMigrationFactory Get-VmfUnattendedStartRefusal { 'changed after the plan sign-off' }
        & $script:Pass | Should -BeNullOrEmpty
        $script:starts.Count | Should -Be 1
        (& $script:Said 'warn') | Should -BeLike '*select Cancel the scheduled start, then select Start this wave*'
    }

    It 'kill-resume: the pass stops between the start and its record, and the engine then refuses - the schedule goes back to pending' {
        & $script:MockArm -Codes @('lost', '202')
        { & $script:Pass } | Should -Throw '*connection was closed*'
        (& $script:Schedule).state | Should -BeExactly 'starting'
        & $script:EditWave
        (& $script:Engine $script:starts[0]) | Should -BeLike '*It stays scheduled*'
        & $script:AssertPending $script:first
        & $script:EndAll
        & $script:Pass | Should -BeNullOrEmpty
        $script:starts.Count | Should -Be 1
        & $script:Approve
        @((& $script:Pass).Wave) | Should -Be @('w1')
        $script:starts.Count | Should -Be 2
    }

    It 'kill-resume: a pass while the start runs records it and leaves it; the engine then refuses - pending' {
        & $script:MockArm -Codes @('lost')
        { & $script:Pass } | Should -Throw '*connection was closed*'
        # The next pass finds the start in Azure, running: it records the
        # execution, and neither removes the schedule nor starts the wave.
        & $script:Pass | Should -BeNullOrEmpty
        $doc = & $script:Schedule
        $doc.state | Should -BeExactly 'started'
        @($doc.executions) | Should -Be @('exec-1')
        $script:starts.Count | Should -Be 1
        & $script:EditWave
        (& $script:Engine $script:starts[0]) | Should -BeLike '*It stays scheduled*'
        & $script:AssertPending $script:first
    }

    It 'kill-resume: an engine run that stopped before its check is not started again; the service removes the start time after it' {
        & $script:MockArm
        & $script:Pass | Out-Null
        (& $script:Schedule).state | Should -BeExactly 'started'
        # The engine container stopped before it read the wave.
        & $script:EndAll
        & $script:Pass | Should -BeNullOrEmpty
        $script:starts.Count | Should -Be 1 -Because 'a start that was made is never made again'
        (& $script:Schedule) | Should -BeNullOrEmpty
    }

    It 'a started schedule whose runs Azure does not list stays, and the service log says why' {
        # A listing that fails reads as a run that may go on: the start time
        # stays for the engine, and nothing is removed or started.
        & $script:MockArm
        & $script:Pass | Out-Null
        (& $script:Schedule).state | Should -BeExactly 'started'
        & $script:EndAll
        $script:Listings = 0
        $script:ListFailsAfter = 0
        $warned = $null
        $r = @(Invoke-VmfFacadeReleaseDueSchedules -StorePath $script:rp -RunId 'swv' -AsOf (Get-Date).ToUniversalTime().AddHours(1) -WarningVariable warned -WarningAction SilentlyContinue)
        $r | Should -BeNullOrEmpty
        (& $script:Schedule).state | Should -BeExactly 'started' -Because 'a run the service cannot see may still remove the schedule or put it to pending again'
        $script:starts.Count | Should -Be 1
        (@($warned) -join "`n") | Should -BeLike '*the runs of the scheduled start of wave w1 could not be listed, so its start time stays*'
        # Azure lists again: the run ended, so the start time goes.
        $script:ListFailsAfter = -1
        & $script:Pass | Should -BeNullOrEmpty
        (& $script:Schedule) | Should -BeNullOrEmpty
        $script:starts.Count | Should -Be 1
    }

    It 'a starting record whose run Azure lists once, then does not list again, is left: nothing starts and nothing is removed' {
        & $script:MockArm -Codes @('lost')
        { & $script:Pass } | Should -Throw '*connection was closed*'
        (& $script:Schedule).state | Should -BeExactly 'starting'
        # The first listing finds the start; the second, which asks whether
        # its run goes on, is not given.
        $script:Listings = 0
        $script:ListFailsAfter = 1
        { & $script:Pass } | Should -Throw '*Could not list engine executions: HTTP 503*'
        (& $script:Schedule).state | Should -BeExactly 'starting' -Because 'a run the service cannot see is never settled for it'
        $script:starts.Count | Should -Be 1
    }

    It 'a schedule the engine cannot put back: the words say the wave is not scheduled' {
        & $script:MockArm
        & $script:Pass | Out-Null
        Remove-Item (& $script:ScheduleFile) -Force
        & $script:EditWave
        $why = & $script:Engine $script:starts[0]
        $why | Should -BeLike 'Wave w1 changed after the service checked it for its scheduled start, so it did not start.*'
        $why | Should -BeLike '*could not keep its schedule*'
        $why | Should -Not -BeLike '*stays scheduled*'
        Test-Path (& $script:ScheduleFile) | Should -BeFalse -Because 'a schedule that is gone is not written again'
    }

    It 'the engine removes only the schedule as it read it, version-checked (PLANVER-2)' {
        & $script:MockArm
        & $script:Pass | Out-Null
        $text = [System.IO.File]::ReadAllText((& $script:ScheduleFile))
        $want = InModuleScope VmMigrationFactory -Parameters @{ t = $text } { param($t) Get-VmfDocumentVersion -Text $t }
        $script:removedVersion = $null
        Mock -ModuleName VmMigrationFactory Remove-VmfStoreItemIfVersion -ParameterFilter { $RelPath -eq 'schedules/w1.json' } { $script:removedVersion = $ExpectedVersion; $true }
        & $script:Engine $script:starts[0] | Out-Null
        $script:removedVersion | Should -BeExactly $want
    }

    It 'the engine never puts back or removes a schedule of another start' {
        & $script:MockArm
        & $script:Pass | Out-Null
        $other = $script:starts[0] -replace [regex]::Escape((& $script:Env $script:starts[0] 'VMF_SCHEDULE_START')), ('f' * 32)
        $before = [System.IO.File]::ReadAllText((& $script:ScheduleFile))
        (& $script:Engine $other) | Should -Not -BeLike '*changed after the service checked it*'
        [System.IO.File]::ReadAllText((& $script:ScheduleFile)) | Should -BeExactly $before -Because 'its start id is not this start'
        & $script:EditWave
        (& $script:Engine $other) | Should -BeLike '*could not keep its schedule*'
        [System.IO.File]::ReadAllText((& $script:ScheduleFile)) | Should -BeExactly $before
    }

    It 'a start that is not a scheduled start keeps its words, and touches no schedule' {
        & $script:MockArm
        & $script:Pass | Out-Null
        $before = [System.IO.File]::ReadAllText((& $script:ScheduleFile))
        $plain = [string]$script:starts[0] -replace '"VMF_SCHEDULE_START"', '"VMF_NOT_A_SCHEDULE"'
        & $script:EditWave
        (& $script:Engine $plain) | Should -BeExactly 'Wave w1 changed after the service checked it for this start, so it did not start. The service checks the wave again at its next check.'
        [System.IO.File]::ReadAllText((& $script:ScheduleFile)) | Should -BeExactly $before
    }

    It 'a started schedule is refused a cancel with words that say when the start time goes' {
        & $script:MockArm
        & $script:Pass | Out-Null
        { Invoke-VmfFacadeSchedule -Principal $script:operator -StorePath $script:rp -Wave 'w1' -Cancel -Note 'moved' } |
            Should -Throw '409: The service started wave w1 at its scheduled time, or is starting it now, so you cannot change its scheduled start. The engine removes the start time when it starts the wave. If the wave changed, the wave stays scheduled.'
    }

    It 'the engine entrypoint gives the wave operation the scheduled start id' {
        $entry = Get-VmfCodeOnly -Text (Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw) -Language PowerShell
        $entry | Should -Match ([regex]::Escape('if ($env:VMF_SCHEDULE_START) { $waveParams.ScheduleStartId = [string]$env:VMF_SCHEDULE_START }'))
    }
}

Describe 'SCHEDULE-WAVE-VERSION-1: what the engine run of a start may remove or put back' {
    It 'only the record of the same start: starting or started, with the same start id' {
        InModuleScope VmMigrationFactory {
            $id = '0123456789abcdef0123456789abcdef'
            Test-VmfScheduleOfStart -Schedule ([pscustomobject]@{ state = 'starting'; startId = $id }) -StartId $id | Should -BeTrue
            Test-VmfScheduleOfStart -Schedule @{ state = 'started'; startId = $id } -StartId $id | Should -BeTrue
            Test-VmfScheduleOfStart -Schedule ([pscustomobject]@{ state = 'pending' }) -StartId $id | Should -BeFalse -Because 'a pending schedule has no start on record'
            Test-VmfScheduleOfStart -Schedule ([pscustomobject]@{ state = 'started'; startId = ('f' * 32) }) -StartId $id | Should -BeFalse -Because 'another start'
            Test-VmfScheduleOfStart -Schedule ([pscustomobject]@{ state = 'started'; startId = $id.ToUpperInvariant() }) -StartId $id | Should -BeFalse -Because 'a start id is compared as written'
            Test-VmfScheduleOfStart -Schedule ([pscustomobject]@{ state = 'other'; startId = $id }) -StartId $id | Should -BeFalse
            Test-VmfScheduleOfStart -Schedule $null -StartId $id | Should -BeFalse
        }
    }

    It 'the service''s put-back still takes only a starting record, at the version it judged' {
        # The facade's form (-Version) is unchanged: a started record is the
        # engine's to put back, never the service's.
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'ScheduleStart.ps1') -Language PowerShell
        $code | Should -Match ([regex]::Escape("elseif ([string]`$doc['state'] -ne 'starting') { return `$false }"))
    }
}