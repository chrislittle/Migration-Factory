#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# AN-TRAFFIC-VERIFY-1 (2026-11-14): a machine whose accelerated path
# carries no traffic must not be recorded as migrated with "accelerated
# networking is in use". The owner: never NetVSC.
#
# Microsoft, and CLAUDE.md DRIVER-1: a loaded driver proves nothing. The proof
# is the virtual function counters (ethtool -S <iface> | grep vf_rx_packets on
# Linux; the virtual function adapter's own packet counters on Windows).
#
# Guests report the counters as a fact (vfTraffic: yes, no or unknown), read
# AFTER the guest sent a few Instance Metadata Service requests. The ENGINE
# judges: in Verifying, an adapter that is present with no traffic is not
# ready - the wait for a late adapter (AN-AMDV7-VF-GAP-1) goes on, and at its
# end the step fails and the machine is rolled back. Counters that could not
# be read are said, and do not stop the move (the same as an Instance Metadata
# Service reading with no answer).

BeforeDiscovery {
    # A real bash: on Windows, the WSL launchers named bash print nothing
    # without a distribution, so they are not one.
    $script:atvHasBash = [bool](@(@(Get-Command bash -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object Source) +
        @(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git' 'bin' 'bash.exe' }) |
        Where-Object { $_ -and (Test-Path $_) -and $_ -notmatch 'WindowsApps|System32' }).Count)
}

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-antraffic'
    $script:work = New-VmfTestTemp -Prefix 'antraffic'

    function script:New-AtvReading {
        # A guest reading: the adapter check, and the traffic fact when given.
        param([string]$Adapter = 'mana', [string]$Traffic)
        $checks = [System.Collections.Generic.List[object]]::new()
        switch ($Adapter) {
            'mana' { $checks.Add([pscustomobject]@{ name = 'interface enP1s1'; status = 'PASS'; detail = 'using MANA driver' }) }
            'sriov' { $checks.Add([pscustomobject]@{ name = 'sriov vf bound enP1s1'; status = 'PASS'; detail = 'using mlx5_core (SR-IOV VF, up)' }) }
            'win' { $checks.Add([pscustomobject]@{ name = 'mana adapter bound'; status = 'PASS'; detail = 'Ethernet 3' }) }
            default { $checks.Add([pscustomobject]@{ name = 'sriov vf bound'; status = 'INFO'; detail = 'no SR-IOV VF interface up' }) }
        }
        $facts = [ordered]@{ os = 'Linux' }
        if ($Traffic) {
            $facts.vfTraffic = $Traffic
            $status = switch ($Traffic) { 'yes' { 'PASS' } 'no' { 'WARN' } default { 'INFO' } }
            $checks.Add([pscustomobject]@{ name = 'vf carrying traffic (eth0)'; status = $status; detail = "traffic: $Traffic" })
        }
        [pscustomobject]@{ result = 'READY'; checks = @($checks); facts = [pscustomobject]$facts; warnings = @() }
    }

    function Global:AtvRun {
        param([string]$ScriptName = 'mana-check.sh')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId; sn = $ScriptName } {
            Wait-VmfAcceleratedAdapter -Context @{ RunPath = $rp; VmId = $vm; Rg = 'rg-lab'; VmName = 'vm-antraffic' } -ScriptName $sn
        }
    }
}

AfterAll {
    Remove-Item 'function:\AtvRun' -ErrorAction SilentlyContinue
    Remove-Variable atvReads, atvLines, atvQueue -Scope Global -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
}

Describe 'AN-TRAFFIC-VERIFY-1: the engine reads the traffic fact' {
    It 'yes, no and unknown are read as the guest said them' {
        foreach ($t in 'yes', 'no', 'unknown') {
            $r = New-AtvReading -Traffic $t
            InModuleScope VmMigrationFactory -Parameters @{ r = $r } { (Get-VmfVfTrafficVerdict -Reading $r).Verdict } | Should -Be $t
        }
    }

    It 'no fact, an empty fact, another word and no reading are unknown - never yes, never no' {
        $odd = New-AtvReading; $odd.facts | Add-Member -NotePropertyName vfTraffic -NotePropertyValue 'maybe'
        $empty = New-AtvReading; $empty.facts | Add-Member -NotePropertyName vfTraffic -NotePropertyValue ''
        foreach ($r in (New-AtvReading), $odd, $empty, $null, [pscustomobject]@{ result = 'READY'; checks = @() }) {
            InModuleScope VmMigrationFactory -Parameters @{ r = $r } { (Get-VmfVfTrafficVerdict -Reading $r).Verdict } | Should -Be 'unknown'
        }
    }

    It 'the detail is the guest''s own traffic line' {
        $r = New-AtvReading -Traffic 'no'
        InModuleScope VmMigrationFactory -Parameters @{ r = $r } { (Get-VmfVfTrafficVerdict -Reading $r).Detail } | Should -Be 'traffic: no'
    }
}

Describe 'AN-TRAFFIC-VERIFY-1: the wait for the adapter asks for traffic too' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-antraffic-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            Initialize-VmfRun -RunPath $rp -RunId 'antraffic-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'antraffic-test' -VmId $vm | Out-Null
        }
        $global:atvReads = 0
        $global:atvQueue = [System.Collections.Generic.List[object]]::new()
        $global:atvLines = [System.Collections.Generic.List[object]]::new()
        $global:atvLast = New-AtvReading -Traffic 'no'
        # Each read takes the next reading in the queue; an empty queue repeats the last one.
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            $global:atvReads++
            if ($global:atvQueue.Count) { $global:atvLast = $global:atvQueue[0]; $global:atvQueue.RemoveAt(0) }
            $global:atvLast
        }
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine {
            $global:atvLines.Add([pscustomobject]@{ Step = $Step; Outcome = $Outcome; Detail = $Detail })
        }
        Mock -ModuleName VmMigrationFactory Start-Sleep { }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
        Remove-Variable atvLast -Scope Global -ErrorAction SilentlyContinue
    }

    It 'an adapter with traffic on the first read: ready at once, and the result carries the traffic' {
        $global:atvQueue.Add((New-AtvReading -Traffic 'yes'))
        $r = Global:AtvRun
        $r.Reads | Should -Be 1
        $r.Waited | Should -BeFalse
        $r.Traffic.Verdict | Should -Be 'yes'
        $global:atvLines.Count | Should -Be 0
    }

    It 'an adapter whose counters could not be read is ready at once: unknown does not hold the step' {
        $global:atvQueue.Add((New-AtvReading -Traffic 'unknown'))
        $r = Global:AtvRun
        $r.Reads | Should -Be 1
        $r.Traffic.Verdict | Should -Be 'unknown'
    }

    It 'an adapter with no traffic is not ready: the wait starts, with its own line' {
        $global:atvQueue.AddRange([object[]]@((New-AtvReading -Traffic 'no'), (New-AtvReading -Traffic 'no'), (New-AtvReading -Traffic 'yes')))
        $r = Global:AtvRun
        $r.Reads | Should -Be 3
        $r.Waited | Should -BeTrue
        $r.Traffic.Verdict | Should -Be 'yes'
        $global:atvLines[0].Outcome | Should -Be 'info'
        $global:atvLines[0].Detail | Should -Be 'The accelerated networking adapter is present, but its packet counters show no traffic. The product checks again every 30 seconds for up to 15 minutes.'
        $global:atvLines[-1].Detail | Should -Match '^The accelerated networking adapter is ready after \d+ seconds\. The product checked it 3 times\.$'
    }

    It 'no traffic for the whole wait: the step fails, and the stop says the adapter carried no traffic' {
        $err = $null
        try { $null = Global:AtvRun } catch { $err = $_.Exception.Message }
        $err | Should -Be 'The accelerated networking adapter is present, but its packet counters showed no traffic in 15 minutes. The product checked it 31 times.'
        $global:atvReads | Should -Be 31
    }

    It 'the adapter went away at the end of the wait: the stop is the one for no adapter, as before' {
        $global:atvQueue.AddRange([object[]]@(@(1..30 | ForEach-Object { New-AtvReading -Traffic 'no' }) + @(New-AtvReading -Adapter 'none')))
        $err = $null
        try { $null = Global:AtvRun } catch { $err = $_.Exception.Message }
        $err | Should -Be 'The accelerated networking adapter did not become ready in 15 minutes. The product checked it 31 times, and found no MANA interface and no SR-IOV virtual function.'
    }

    It 'the retry of the step after a wait with no traffic reads once and fails with the same stop' {
        try { $null = Global:AtvRun } catch { $null = $_ }
        $global:atvReads = 0
        $err = $null
        try { $null = Global:AtvRun } catch { $err = $_.Exception.Message }
        $err | Should -Match '^The accelerated networking adapter is present, but its packet counters showed no traffic in 15 minutes\. The product checked it 32 times\.'
        $global:atvReads | Should -Be 1
    }

    It 'the <a> adapter is held to the same rule' -ForEach @(@{ a = 'win' }, @{ a = 'sriov' }) {
        $global:atvLast = New-AtvReading -Adapter $a -Traffic 'no'
        $err = $null
        try { $null = Global:AtvRun -ScriptName 'Test-ManaReady.ps1' } catch { $err = $_.Exception.Message }
        $err | Should -Match '^The accelerated networking adapter is present, but its packet counters showed no traffic in 15 minutes\.' -Because "the $a adapter with no traffic"
    }
}

Describe 'AN-TRAFFIC-VERIFY-1: the Windows script reads the virtual function counters' {
    # The script is RUN, under Windows PowerShell 5.1 when it is here (the
    # interpreter RunCommand uses), with only the reads of the machine replaced.
    BeforeAll {
        $script:winScript = Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Test-ManaReady.ps1'
        $winPs = Get-Command powershell.exe -ErrorAction SilentlyContinue
        $script:shell = if ($winPs) { $winPs.Source } else { (Get-Process -Id $PID).Path }
        $harness = @'
param([string]$ScenarioPath, [string]$GuestScript)
$s = Get-Content -LiteralPath $ScenarioPath -Raw | ConvertFrom-Json
function Get-CimInstance { param([Parameter(Position = 0)]$ClassName) [pscustomobject]@{ Caption = 'Microsoft Windows Server (test)'; Version = '10.0.20348' } }
function Get-ChildItem { [CmdletBinding()] param([Parameter(Position = 0)]$Path, $Filter) }
function Get-NetAdapter {
    [CmdletBinding()] param()
    @($s.adapters | ForEach-Object { [pscustomobject]@{ Name = $_.name; Status = $_.status; DriverDescription = $_.desc; InterfaceDescription = $_.desc; DriverVersion = '1.0' } })
}
function Get-NetAdapterStatistics {
    [CmdletBinding()] param([string]$Name)
    $a = @($s.adapters | Where-Object { $_.name -eq $Name })[0]
    if ($a.statsThrow) { throw 'No MSFT_NetAdapterStatisticsSettingData objects found' }
    [pscustomobject]@{ Name = $Name; ReceivedUnicastPackets = $a.rx; SentUnicastPackets = $a.tx }
}
& $GuestScript
'@
        $script:harnessPath = Join-Path $script:work 'harness.ps1'
        [System.IO.File]::WriteAllText($script:harnessPath, $harness, [System.Text.UTF8Encoding]::new($true))

        function script:Invoke-AtvWin {
            param([object[]]$Adapters)
            $scenarioPath = Join-Path $script:work ('scenario-{0}.json' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
            @{ adapters = @($Adapters) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $scenarioPath -Encoding utf8
            $raw = & $script:shell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:harnessPath -ScenarioPath $scenarioPath -GuestScript $script:winScript 2>&1
            $json = [string](@($raw | Where-Object { [string]$_ -match '^\{' }) | Select-Object -Last 1)
            if (-not $json) { throw "the guest script gave no JSON: $($raw -join ' ')" }
            Test-Json -Json $json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json') -ErrorAction Stop | Should -BeTrue
            ConvertFrom-VmfGuestOutput -RawOutput $json
        }
        $script:manaDesc = 'Microsoft Azure Network Adapter'
        $script:mlxDesc = 'Mellanox ConnectX-4 Lx Virtual Ethernet Adapter'
    }

    It 'a MANA adapter that is up with packets: yes, and the check shows the counters' {
        $doc = Invoke-AtvWin @(@{ name = 'Ethernet 3'; status = 'Up'; desc = $script:manaDesc; rx = 120; tx = 80 })
        $doc.facts.vfTraffic | Should -Be 'yes'
        $c = @($doc.checks | Where-Object name -eq 'vf carrying traffic')[0]
        $c.status | Should -Be 'PASS'
        $c.detail | Should -Match 'Ethernet 3'
        $c.detail | Should -Match '120'
        $c.detail | Should -Match '80'
    }

    It 'a Mellanox adapter that is up with packets: yes' {
        $doc = Invoke-AtvWin @(@{ name = 'Ethernet 2'; status = 'Up'; desc = $script:mlxDesc; rx = 0; tx = 5 })
        $doc.facts.vfTraffic | Should -Be 'yes'
    }

    It 'an adapter that is up with no packets: no' {
        $doc = Invoke-AtvWin @(@{ name = 'Ethernet 3'; status = 'Up'; desc = $script:manaDesc; rx = 0; tx = 0 })
        $doc.facts.vfTraffic | Should -Be 'no'
        @($doc.checks | Where-Object name -eq 'vf carrying traffic')[0].status | Should -Be 'WARN'
    }

    It 'an adapter that is disabled carries no traffic, whatever its counters say: no' {
        $doc = Invoke-AtvWin @(@{ name = 'Ethernet 3'; status = 'Disabled'; desc = $script:manaDesc; rx = 500; tx = 500 })
        $doc.facts.vfTraffic | Should -Be 'no'
    }

    It 'counters that cannot be read: unknown, never yes or no' {
        $doc = Invoke-AtvWin @(@{ name = 'Ethernet 3'; status = 'Up'; desc = $script:manaDesc; statsThrow = $true })
        $doc.facts.vfTraffic | Should -Be 'unknown'
    }

    It 'no virtual function adapter at all (before the move, on a size with none): unknown' {
        $doc = Invoke-AtvWin @(@{ name = 'Ethernet'; status = 'Up'; desc = 'Microsoft Hyper-V Network Adapter'; rx = 9; tx = 9 })
        $doc.facts.vfTraffic | Should -Be 'unknown'
    }

    It 'the counters are read AFTER the Instance Metadata Service requests, and the requests keep its rules' {
        $code = Get-VmfCodeOnly -Path $script:winScript
        $send = $code.IndexOf('Send-VfTraffic')
        $send | Should -BeGreaterThan -1
        # The call (the last mention), before the read of the counters after it.
        $call = $code.LastIndexOf('Send-VfTraffic')
        $call | Should -BeGreaterThan $send -Because 'the function is defined, then called'
        $afterRead = $code.LastIndexOf('Read-VfCounters')
        $afterRead | Should -BeGreaterThan $call -Because 'the counters that decide are read after the requests'
        $code | Should -Match '\.Proxy = \$null' -Because 'Windows PowerShell 5.1 has no -NoProxy (VERIFY-FP-1)'
        $code | Should -Match "Headers\.Add\('Metadata', 'true'\)"
        $code | Should -Match 'Start-Sleep -Milliseconds 300' -Because 'at most 5 requests a second'
    }
}

Describe 'AN-TRAFFIC-VERIFY-1: the Linux script reads the counters after traffic' {
    BeforeAll {
        $script:linScript = Join-Path $script:repoRoot 'src' 'guest' 'linux' 'mana-check.sh'
        $script:bash = @(@(Get-Command bash -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object Source) +
            @(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git' 'bin' 'bash.exe' }) |
            Where-Object { $_ -and (Test-Path $_) -and $_ -notmatch 'WindowsApps|System32' }) | Select-Object -First 1
        # Git Bash on Windows takes /c/... paths; a Linux bash takes the path as it is.
        $script:hasCygpath = [bool](& $script:bash -c 'command -v cygpath' | Out-String).Trim()
        function script:ConvertTo-AtvUnix([string]$PathText) {
            if ($script:hasCygpath) { return (& $script:bash -c "cygpath -u '$PathText'" | Out-String).Trim() }
            $PathText
        }
        function script:Invoke-AtvLinux {
            # Interfaces: name -> @{ driver; state; stats = @(before, after) or a single text }.
            param([hashtable]$Interfaces)
            $case = Join-Path $script:work ('lin-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
            $net = Join-Path $case 'sys' 'class' 'net'
            $bin = Join-Path $case 'bin'
            $null = New-Item -ItemType Directory -Path $net, $bin -Force
            foreach ($name in $Interfaces.Keys) {
                $i = $Interfaces[$name]
                $null = New-Item -ItemType Directory -Path (Join-Path $net $name) -Force
                [System.IO.File]::WriteAllText((Join-Path $net $name 'operstate'), "$($i.state)`n")
                [System.IO.File]::WriteAllText((Join-Path $case "$name.driver"), "$($i.driver)`n")
                [System.IO.File]::WriteAllText((Join-Path $case "$name.stats0"), "$($i.before)`n")
                [System.IO.File]::WriteAllText((Join-Path $case "$name.stats1"), "$($i.after)`n")
            }
            $null = New-Item -ItemType Directory -Path (Join-Path $net 'lo') -Force
            $u = ConvertTo-AtvUnix $case
            # Stand-ins. ethtool -S gives the counters before any metadata
            # request, and the second set once curl has been called.
            $ethtool = @'
#!/bin/bash
D="__CASE__"
echo "ethtool $*" >> "$D/calls"
if [ "$1" = "-i" ]; then [ -f "$D/$2.driver" ] && echo "driver: $(cat "$D/$2.driver")" && echo "version: 1.0"; exit 0; fi
if [ "$1" = "-S" ]; then
  if [ -f "$D/curled" ]; then f="$D/$2.stats1"; else f="$D/$2.stats0"; fi
  [ -f "$f" ] && cat "$f"; exit 0
fi
'@
            $curl = @'
#!/bin/bash
D="__CASE__"
echo "curl $*" >> "$D/calls"
touch "$D/curled"
exit 0
'@
            $empty = "#!/bin/bash`nexit 1`n"
            $sleep = "#!/bin/bash`necho `"sleep `$*`" >> `"$u/calls`"`nexit 0`n"
            [System.IO.File]::WriteAllText((Join-Path $bin 'sleep'), $sleep)
            [System.IO.File]::WriteAllText((Join-Path $bin 'ethtool'), $ethtool.Replace('__CASE__', $u).Replace("`r", ''))
            [System.IO.File]::WriteAllText((Join-Path $bin 'curl'), $curl.Replace('__CASE__', $u).Replace("`r", ''))
            [System.IO.File]::WriteAllText((Join-Path $bin 'lsmod'), $empty)
            [System.IO.File]::WriteAllText((Join-Path $bin 'modinfo'), $empty)
            $uScript = ConvertTo-AtvUnix $script:linScript
            $out = & $script:bash -c "chmod +x '$u/bin/'*; PATH='$u/bin:'`$PATH VMF_TEST_ROOT='$u' bash '$uScript'"
            $json = ($out | Out-String).Trim()
            Test-Json -Json $json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json') -ErrorAction Stop | Should -BeTrue
            $calls = @(if (Test-Path (Join-Path $case 'calls')) { Get-Content (Join-Path $case 'calls') })
            @{ Doc = (ConvertFrom-VmfGuestOutput -RawOutput $json); Calls = $calls }
        }
        # A per-processor counter first, so only the exact total name can give the total.
        $script:stats = { param($rx, $tx) "NIC statistics:`n     cpu0_vf_rx_packets: 7`n     cpu0_vf_tx_packets: 7`n     tx_packets: 999`n     vf_rx_packets: $rx`n     vf_tx_packets: $tx" }
    }

    # Each run of the script here forks some hundred processes, and Git Bash
    # forks slowly on Windows: so four runs, each proving several rules.
    It 'counters that moved on one interface of two, after the metadata requests: yes, both readings kept, requests first and inside the rules' -Skip:(-not $script:atvHasBash) {
        $r = Invoke-AtvLinux @{
            eth0 = @{ driver = 'hv_netvsc'; state = 'up'; before = (& $script:stats 0 0); after = (& $script:stats 0 0) }
            eth1 = @{ driver = 'hv_netvsc'; state = 'up'; before = (& $script:stats 0 0); after = (& $script:stats 15 9) }
            enP1s1 = @{ driver = 'mana'; state = 'up'; before = ''; after = '' } }
        $r.Doc.facts.vfTraffic | Should -Be 'yes' -Because 'one interface with traffic is enough, and only the reading after the requests shows it'
        $c = @($r.Doc.checks | Where-Object name -like 'vf carrying traffic*')[0]
        $c.name | Should -Be 'vf carrying traffic (eth1)'
        $c.status | Should -Be 'PASS'
        $c.detail | Should -Match 'vf_rx_packets=15 vf_tx_packets=9 after the metadata requests'
        $c.detail | Should -Match 'before them: vf_rx_packets=0 vf_tx_packets=0' -Because 'the reading before the requests is kept as evidence'
        $curls = @($r.Calls | Where-Object { $_ -like 'curl *' })
        $curls.Count | Should -Be 3
        $curls[0] | Should -Match '169\.254\.169\.254'
        $curls[0] | Should -Match 'Metadata: true'
        $curls[0] | Should -Match '--noproxy'
        # At most 5 requests a second: a pause of 0.3 seconds after each request.
        $paced = @($r.Calls | Where-Object { $_ -like 'curl *' -or $_ -like 'sleep *' } | ForEach-Object { ($_ -split ' ')[0..1] -join ' ' })
        $paced | Should -Be @('curl -s', 'sleep 0.3', 'curl -s', 'sleep 0.3', 'curl -s', 'sleep 0.3')
        $lastStats = [array]::LastIndexOf([string[]]$r.Calls, 'ethtool -S eth1')
        $lastCurl = [array]::LastIndexOf([string[]]$r.Calls, $curls[-1])
        $lastStats | Should -BeGreaterThan $lastCurl -Because 'the counters that decide are read after the requests'
    }

    It 'totals at zero after the requests: no - and a per-processor counter is not read as the total' -Skip:(-not $script:atvHasBash) {
        $r = Invoke-AtvLinux @{
            eth0 = @{ driver = 'hv_netvsc'; state = 'up'; before = (& $script:stats 0 0); after = (& $script:stats 0 0) }
            enP1s1 = @{ driver = 'mana'; state = 'up'; before = ''; after = '' } }
        $r.Doc.facts.vfTraffic | Should -Be 'no'
        $c = @($r.Doc.checks | Where-Object name -like 'vf carrying traffic*')[0]
        $c.status | Should -Be 'WARN'
        $c.detail | Should -Match 'vf_rx_packets=0 vf_tx_packets=0'
    }

    It 'a virtual function interface that is down carries no traffic, whatever the counters from earlier in the boot say: no' -Skip:(-not $script:atvHasBash) {
        $r = Invoke-AtvLinux @{
            eth0 = @{ driver = 'hv_netvsc'; state = 'up'; before = (& $script:stats 40 40); after = (& $script:stats 40 40) }
            enP1s1 = @{ driver = 'mana'; state = 'down'; before = ''; after = '' } }
        $r.Doc.facts.vfTraffic | Should -Be 'no'
        @($r.Doc.checks | Where-Object name -like 'vf carrying traffic*')[0].detail | Should -Match 'enP1s1'
    }

    It 'no interface gives virtual function counters: unknown' -Skip:(-not $script:atvHasBash) {
        $r = Invoke-AtvLinux @{
            eth0 = @{ driver = 'hv_netvsc'; state = 'up'; before = 'NIC statistics:'; after = 'NIC statistics:' } }
        $r.Doc.facts.vfTraffic | Should -Be 'unknown'
    }
}
