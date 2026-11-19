#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# AN-AMDV7-VF-GAP-1 (2026-11-06: find out why the adapter was late, and
# retry; the wait window is 15 minutes).
#
# Measured 2026-11-06, 20 starts each on Ubuntu 22.04: on Intel
# Standard_D2s_v6 the accelerated networking virtual function appeared 3.6 to
# 6.2 seconds after boot, every time. On AMD Standard_D2as_v7 it was late on 9
# of 20 starts (56 to 435 seconds). It always arrived, and traffic flowed
# through it; the synthetic interface carried the network during the wait.
#
# Verifying read the adapter ONCE and rolled back a healthy machine whose
# virtual function had not arrived yet. Now a first read with no adapter
# starts a wait: a read every 30 seconds, for up to 15 minutes, before the
# step fails as it did before. The wait is checkpointed in the state document
# (captured.anAdapterWait), so a worker that stops during it is resumed in the
# SAME wait - never a new 15 minutes, never a read counted twice.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-anwait'

    # Guest readings, the shapes mana-check.sh and Test-ManaReady.ps1 give.
    $script:noAdapter = [pscustomobject]@{ result = 'READY'; checks = @(
            [pscustomobject]@{ name = 'mana module available'; status = 'PASS'; detail = '/lib/modules/mana.ko' },
            [pscustomobject]@{ name = 'sriov vf bound'; status = 'INFO'; detail = 'no SR-IOV VF interface up' }); warnings = @() }
    $script:manaBound = [pscustomobject]@{ result = 'READY'; checks = @(
            [pscustomobject]@{ name = 'interface eth1'; status = 'PASS'; detail = 'using MANA driver' }); warnings = @() }
    $script:sriovBound = [pscustomobject]@{ result = 'READY'; checks = @(
            [pscustomobject]@{ name = 'sriov vf bound eth1'; status = 'PASS'; detail = 'using mlx5_core (SR-IOV VF, up)' }); warnings = @() }
    $script:winBound = [pscustomobject]@{ result = 'READY'; checks = @(
            [pscustomobject]@{ name = 'mana adapter bound'; status = 'PASS'; detail = 'Ethernet 3' }); warnings = @() }

    function Global:AnwRun {
        # One call of the wait, as VALIDATING makes it. Returns the result, or
        # the error text when it throws.
        param([string]$ScriptName = 'mana-check.sh')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId; sn = $ScriptName } {
            Wait-VmfAcceleratedAdapter -Context @{ RunPath = $rp; VmId = $vm; Rg = 'rg-lab'; VmName = 'vm-anwait' } -ScriptName $sn
        }
    }
    function Global:AnwDoc {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            Read-VmfStateDoc -RunPath $rp -VmId $vm
        }
    }
    function Global:AnwWait {
        $d = Global:AnwDoc
        if ($d.captured -and $d.captured.PSObject.Properties['anAdapterWait']) { $d.captured.anAdapterWait } else { $null }
    }
    function Global:AnwSeed {
        # The checkpoint a worker that stopped during the wait left behind.
        param([int]$Reads, [int]$StartedSecondsAgo)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId; n = $Reads; ago = $StartedSecondsAgo } {
            Save-VmfCapturedFacts -Context @{ RunPath = $rp; VmId = $vm } -Facts @{ anAdapterWait = [ordered]@{
                    firstReadUtc = [datetime]::UtcNow.AddSeconds(-$ago).ToString('o'); reads = $n } }
        }
    }
}

AfterAll {
    Remove-Item 'function:\AnwRun', 'function:\AnwDoc', 'function:\AnwWait', 'function:\AnwSeed' -ErrorAction SilentlyContinue
    Remove-Variable anwReads, anwLines, anwSleeps, anwQueue, anwNone -Scope Global -ErrorAction SilentlyContinue
}

Describe 'AN-AMDV7-VF-GAP-1: the settings' {
    It 'reads again every 30 seconds, for up to 15 minutes, by default' {
        InModuleScope VmMigrationFactory {
            $s = Get-VmfAnAdapterWaitSettings
            $s.IntervalSeconds | Should -Be 30
            $s.WaitMinutes | Should -Be 15
        }
    }

    It 'the settings live beside the other engine settings, and the wait reads them from there' {
        InModuleScope VmMigrationFactory {
            $script:VmfAnAdapterWait.IntervalSeconds | Should -Be 30
            $script:VmfAnAdapterWait.WaitMinutes | Should -Be 15
            $keep = $script:VmfAnAdapterWait.Clone()
            try {
                $script:VmfAnAdapterWait.IntervalSeconds = 10
                $script:VmfAnAdapterWait.WaitMinutes = 2
                $s = Get-VmfAnAdapterWaitSettings
                $s.IntervalSeconds | Should -Be 10
                $s.WaitMinutes | Should -Be 2
            }
            finally { $script:VmfAnAdapterWait = $keep }
        }
    }
}

Describe 'AN-AMDV7-VF-GAP-1: which reading shows the adapter' {
    It 'MANA bound, an SR-IOV virtual function up and the Windows MANA adapter are each ready' {
        foreach ($r in $script:manaBound, $script:sriovBound, $script:winBound) {
            InModuleScope VmMigrationFactory -Parameters @{ r = $r } { (Get-VmfAcceleratedFabric -Reading $r).Bound } | Should -BeTrue
        }
        InModuleScope VmMigrationFactory -Parameters @{ r = $script:manaBound } { (Get-VmfAcceleratedFabric -Reading $r).Fabric } | Should -Be 'mana'
        InModuleScope VmMigrationFactory -Parameters @{ r = $script:sriovBound } { (Get-VmfAcceleratedFabric -Reading $r).Fabric } | Should -Be 'sriov'
    }

    It 'a driver that is only available, an SR-IOV line that is INFO, and no reading are not ready' {
        foreach ($r in $script:noAdapter, $null, [pscustomobject]@{ result = 'READY'; checks = @() },
            [pscustomobject]@{ result = 'READY'; checks = @([pscustomobject]@{ name = 'interface eth1'; status = 'WARN'; detail = 'x' }) }) {
            InModuleScope VmMigrationFactory -Parameters @{ r = $r } { (Get-VmfAcceleratedFabric -Reading $r).Bound } | Should -BeFalse
        }
    }
}

Describe 'AN-AMDV7-VF-GAP-1: the wait' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-anwait-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            Initialize-VmfRun -RunPath $rp -RunId 'anwait-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'anwait-test' -VmId $vm | Out-Null
        }
        $global:anwReads = 0
        $global:anwQueue = [System.Collections.Generic.List[object]]::new()
        $global:anwLines = [System.Collections.Generic.List[object]]::new()
        $global:anwSleeps = [System.Collections.Generic.List[int]]::new()
        $global:anwNone = $script:noAdapter
        # Each read takes the next reading in the queue; an empty queue is no adapter.
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            $global:anwReads++
            if ($global:anwQueue.Count) { $next = $global:anwQueue[0]; $global:anwQueue.RemoveAt(0) } else { $next = 'none' }
            if ($next -is [string] -and $next -like 'throw:*') { throw $next.Substring(6) }
            if ($next -is [string]) { return $global:anwNone }
            $next
        }
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine {
            $global:anwLines.Add([pscustomobject]@{ Step = $Step; Outcome = $Outcome; Detail = $Detail })
        }
        Mock -ModuleName VmMigrationFactory Start-Sleep { $global:anwSleeps.Add([int]$Seconds) }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'an adapter on the first read: one read, no wait, no line, no checkpoint (every Intel start measured)' {
        $global:anwQueue.Add($script:manaBound)
        $r = Global:AnwRun
        $r.Reads | Should -Be 1
        $r.Waited | Should -BeFalse
        $r.Fabric.Fabric | Should -Be 'mana'
        $global:anwReads | Should -Be 1
        $global:anwSleeps.Count | Should -Be 0
        $global:anwLines.Count | Should -Be 0 -Because 'a machine that passes at once says nothing new'
        Global:AnwWait | Should -BeNullOrEmpty
    }

    It 'the Windows adapter on the first read is the same' {
        $global:anwQueue.Add($script:winBound)
        $r = Global:AnwRun -ScriptName 'Test-ManaReady.ps1'
        $r.Reads | Should -Be 1
        Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm -Times 1 -Exactly -ParameterFilter { $ScriptName -eq 'Test-ManaReady.ps1' }
    }

    It 'an adapter on read 4: three reads with none, a wait line, 30 seconds between reads, then ready' {
        $global:anwQueue.AddRange([object[]]@('none', 'none', 'none', $script:sriovBound))
        $r = Global:AnwRun
        $r.Reads | Should -Be 4
        $r.Waited | Should -BeTrue
        $r.Fabric.Fabric | Should -Be 'sriov'
        $r.Reading.checks[0].name | Should -Be 'sriov vf bound eth1' -Because 'the caller records the reading that passed'
        $global:anwReads | Should -Be 4
        @($global:anwSleeps) | Should -Be @(30, 30, 30)
        $first = $global:anwLines[0]
        $first.Outcome | Should -Be 'info'
        $first.Detail | Should -Be 'The accelerated networking adapter is not ready yet. The product checks again every 30 seconds for up to 15 minutes.'
        $done = $global:anwLines[-1]
        $done.Outcome | Should -Be 'ok'
        $done.Detail | Should -Match '^The accelerated networking adapter is ready after \d+ seconds\. The product checked it 4 times\.$'
        Global:AnwWait | Should -BeNullOrEmpty -Because 'a wait that ended is not left for a later attempt to continue'
    }

    It 'the line uses the settings it waits with' {
        $global:anwQueue.AddRange([object[]]@('none', $script:manaBound))
        InModuleScope VmMigrationFactory { $script:VmfAnAdapterWaitKeep = $script:VmfAnAdapterWait.Clone(); $script:VmfAnAdapterWait.IntervalSeconds = 20; $script:VmfAnAdapterWait.WaitMinutes = 5 }
        try { $null = Global:AnwRun }
        finally { InModuleScope VmMigrationFactory { $script:VmfAnAdapterWait = $script:VmfAnAdapterWaitKeep } }
        $global:anwLines[0].Detail | Should -Be 'The accelerated networking adapter is not ready yet. The product checks again every 20 seconds for up to 5 minutes.'
        @($global:anwSleeps) | Should -Be @(20)
    }

    It 'the wait ends when the settings say: 20 seconds for 5 minutes is 16 reads' {
        InModuleScope VmMigrationFactory { $script:VmfAnAdapterWaitKeep = $script:VmfAnAdapterWait.Clone(); $script:VmfAnAdapterWait.IntervalSeconds = 20; $script:VmfAnAdapterWait.WaitMinutes = 5 }
        $err = $null
        try { $null = Global:AnwRun } catch { $err = $_.Exception.Message }
        finally { InModuleScope VmMigrationFactory { $script:VmfAnAdapterWait = $script:VmfAnAdapterWaitKeep } }
        $err | Should -Match '^The accelerated networking adapter did not become ready in 5 minutes\. The product checked it 16 times'
        $global:anwReads | Should -Be 16
    }
    It 'no adapter at all: 31 reads over 15 minutes, then the step fails and the stop names the wait' {
        $err = $null
        try { $null = Global:AnwRun } catch { $err = $_.Exception.Message }
        $err | Should -Be 'The accelerated networking adapter did not become ready in 15 minutes. The product checked it 31 times, and found no MANA interface and no SR-IOV virtual function.'
        $global:anwReads | Should -Be 31 -Because 'the first read, then one every 30 seconds up to 15 minutes'
        $global:anwSleeps.Count | Should -Be 30
        $w = Global:AnwWait
        $w.reads | Should -Be 31 -Because 'the checkpoint stays, so the retry of the step does not wait another 15 minutes'
    }

    It 'the retry of the step after the wait ran out reads once and fails again - no second 15 minutes' {
        try { $null = Global:AnwRun } catch { $null = $_ }
        $global:anwReads = 0; $global:anwSleeps.Clear()
        $err = $null
        try { $null = Global:AnwRun } catch { $err = $_.Exception.Message }
        $err | Should -Match 'did not become ready in 15 minutes\. The product checked it 32 times'
        $global:anwReads | Should -Be 1
        $global:anwSleeps.Count | Should -Be 0
    }

    It 'a wall clock past the window ends the wait even with few reads (a worker that stopped for a long time)' {
        Global:AnwSeed -Reads 2 -StartedSecondsAgo 1000
        $err = $null
        try { $null = Global:AnwRun } catch { $err = $_.Exception.Message }
        $err | Should -Match 'checked it 3 times'
        $global:anwReads | Should -Be 1
    }

    It 'every read is checkpointed before the next one' {
        $global:anwQueue.AddRange([object[]]@('none', 'none', 'throw:Lease for ''vm'' is held by ''worker-2'', not ''worker-1'' - abandon this VM.'))
        { Global:AnwRun } | Should -Throw '*abandon this VM*'
        (Global:AnwWait).reads | Should -Be 2 -Because 'the two reads that finished are on record; the one that stopped is not'
    }

    It 'kill and resume: the worker stops during the wait, and the next one continues the SAME wait' {
        $global:anwQueue.AddRange([object[]]@('none', 'none', 'none', 'throw:Lease for ''vm'' is held by ''worker-2'', not ''worker-1'' - abandon this VM.'))
        { Global:AnwRun } | Should -Throw '*abandon this VM*'
        $before = Global:AnwWait
        $before.reads | Should -Be 3
        $started = [string](InModuleScope VmMigrationFactory -Parameters @{ v = $before.firstReadUtc } { ConvertTo-VmfUtcText -Value $v })

        # The next worker: no adapter, then the adapter.
        $global:anwLines.Clear(); $global:anwReads = 0; $global:anwSleeps.Clear()
        $global:anwQueue.AddRange([object[]]@('none', $script:manaBound))
        $r = Global:AnwRun
        $r.Reads | Should -Be 5 -Because 'three reads before the stop and two after, each counted once'
        $r.Waited | Should -BeTrue
        $global:anwReads | Should -Be 2
        $global:anwLines[0].Detail | Should -Match '^The accelerated networking adapter is still not ready\. The product continues the wait that started at \S+, for up to 15 minutes in all\.$'
        $global:anwLines[0].Detail | Should -BeLike "*$started*" -Because 'the same wait, from the same start'
        Global:AnwWait | Should -BeNullOrEmpty
    }

    It 'kill and resume with no adapter: the reads of both workers add up to one wait of 31 reads, not two' {
        $global:anwQueue.AddRange([object[]]@('none', 'none', 'none', 'none', 'none', 'throw:Lease for ''vm'' is held by ''worker-2'', not ''worker-1'' - abandon this VM.'))
        { Global:AnwRun } | Should -Throw '*abandon this VM*'
        $first = $global:anwReads - 1
        $global:anwReads = 0
        $err = $null
        try { $null = Global:AnwRun } catch { $err = $_.Exception.Message }
        $err | Should -Match 'checked it 31 times'
        ($first + $global:anwReads) | Should -Be 31
    }

    It 'kill and resume: an adapter on the first read after the resume ends the wait at once' {
        Global:AnwSeed -Reads 6 -StartedSecondsAgo 200
        $global:anwQueue.Add($script:manaBound)
        $r = Global:AnwRun
        $r.Reads | Should -Be 7
        $r.Waited | Should -BeTrue
        $global:anwSleeps.Count | Should -Be 0
        $global:anwLines[-1].Detail | Should -Match 'The product checked it 7 times\.$'
        Global:AnwWait | Should -BeNullOrEmpty
    }

    It 'a read that Azure refuses is not counted, and the step fails as any refused read did' {
        $global:anwQueue.AddRange([object[]]@('none', 'throw:Run Command failed: Conflict'))
        { Global:AnwRun } | Should -Throw '*Run Command failed*'
        (Global:AnwWait).reads | Should -Be 1
    }

    It 'the lease is renewed before each wait between reads' {
        InModuleScope VmMigrationFactory { $script:anwBeats = 0; $script:VmfOpHeartbeat = { $script:anwBeats++ } }
        try {
            $global:anwQueue.AddRange([object[]]@('none', 'none', $script:manaBound))
            $null = Global:AnwRun
            InModuleScope VmMigrationFactory { $script:anwBeats } | Should -Be 2
        }
        finally { InModuleScope VmMigrationFactory { $script:VmfOpHeartbeat = $null } }
    }
}

Describe 'AN-AMDV7-VF-GAP-1: a new attempt starts a new wait' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-anwait-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            Initialize-VmfRun -RunPath $rp -RunId 'anwait-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'anwait-test' -VmId $vm | Out-Null
        }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'the rollback, a retry from the first step and a retry of Verifying each clear the wait' {
        foreach ($case in @(@{ From = 'PRECHECK'; New = $false }, @{ From = 'PRECHECK'; New = $true }, @{ From = 'VALIDATING'; New = $true })) {
            Global:AnwSeed -Reads 31 -StartedSecondsAgo 900
            Global:AnwWait | Should -Not -BeNullOrEmpty
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId; c = $case } {
                Clear-VmfRetryState -RunPath $rp -VmId $vm -From $c.From -NewAttempt:$c.New
            }
            Global:AnwWait | Should -BeNullOrEmpty -Because "a retry from $($case.From) is a new attempt at Verifying"
        }
    }
}
