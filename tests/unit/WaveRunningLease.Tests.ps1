#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-RUNNING-LEASE-1: a held lease keeps a wave running, on the pages as in
# the engine - and a lease a stopped worker left on a finished machine is said
# as what it is.
#
# The engine (Get-VmfWaveRunningDetail) counted a wave as running when a
# machine of it had a LEASE or a state that is not final. The pages
# (VmfHelp.machineAtWork) read only the state documents. So a worker that took
# a lease and had not yet written PLANNED, or a lease left after its worker
# stopped, made the Migrations page and the wave editor offer the wave's
# controls while the engine refused every edit and release of it.
#
# Now one rule decides, in two languages: Get-VmfMachineHold here and
# VmfHelp.machineHold in help.js, both held to tests/fixtures/machine-hold.json
# (tests/js/wave-running-lease.test.js runs the pages' copy). Its third answer,
# endedHold, is the hold the service's timer removes (STALE-WAVE-HOLD-1):
# Get-VmfEndedWaveHolds asks the same rule, so a page that says "the service
# removes the hold" says what the service does.
#
# A lease is a contract now (schemas/lease.schema.json, hard rule 1), because
# a page reads it.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'wrl'
    $script:fixtureText = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'machine-hold.json') -Raw
    $script:leaseSchema = Join-Path $script:repoRoot 'schemas' 'lease.schema.json'

    $global:WrlBase = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-wrl/providers/Microsoft.Compute/virtualMachines/'
    $global:WrlA = "${global:WrlBase}vm-a"
    $global:WrlB = "${global:WrlBase}vm-b"

    # A fixture case's lease, as the store gives it back: a heartbeat age
    # becomes a time that long before now.
    function Global:WrlLease($Case) {
        if (-not $Case.lease) { return $null }
        $lease = [ordered]@{ vmId = $global:WrlA; workerId = [string]$Case.lease.workerId }
        if ($Case.lease.PSObject.Properties['heartbeatAgeSeconds']) {
            $lease.heartbeatUtc = (Get-Date).ToUniversalTime().AddSeconds(-[int]$Case.lease.heartbeatAgeSeconds).ToString('o')
        }
        elseif ($Case.lease.PSObject.Properties['heartbeatUtc']) { $lease.heartbeatUtc = [string]$Case.lease.heartbeatUtc }
        ($lease | ConvertTo-Json -Depth 4) | ConvertFrom-Json -Depth 4
    }

    # A run whose plan holds vm-a and vm-b in wave w1.
    function Global:WrlRun {
        $rp = Join-Path $script:temp "wrl-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; a = $global:WrlA; b = $global:WrlB } {
            Initialize-VmfRun -RunPath $rp -RunId 'wrl' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = 8; assessmentRunId = 'wrl'
                entries = @(
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $a; wave = 'w1'; path = 'A' }
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $b; wave = 'w1'; path = 'A' })
            })
        }
        $rp
    }
    function Global:WrlState([string]$RunPath, [string]$VmId, [string]$State) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; id = $VmId; s = $State } {
            $doc = New-VmfStateDoc -RunPath $rp -RunId 'wrl' -VmId $id -Wave 'w1'
            if ($s -ne 'PLANNED') { $doc.state = $s; Write-VmfStateDoc -RunPath $rp -Document $doc | Out-Null }
        }
    }
    function Global:WrlPutLease([string]$RunPath, [string]$VmId, [string]$WorkerId, [int]$AgeSeconds) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; id = $VmId; w = $WorkerId; age = $AgeSeconds } {
            $hb = (Get-Date).ToUniversalTime().AddSeconds(-$age).ToString('o')
            Write-VmfStoreJson -RunPath $rp -RelPath (Get-VmfLeaseRelPath -VmId $id) -Depth 4 -Document ([ordered]@{
                schemaVersion = 1; vmId = $id; workerId = $w; acquiredUtc = $hb; heartbeatUtc = $hb })
        }
    }
}
AfterAll { if ($script:temp -and (Test-Path $script:temp)) { Remove-Item $script:temp -Recurse -Force -ErrorAction SilentlyContinue } }

Describe 'WAVE-RUNNING-LEASE-1: the one rule (Get-VmfMachineHold)' {
    BeforeDiscovery {
        $text = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'machine-hold.json') -Raw
        $script:cases = @(($text | ConvertFrom-Json -Depth 10).cases | ForEach-Object { @{ Name = $_.name; Hold = [string]$_.hold } })
    }

    It 'the fixture holds the cases the pages read wrongly, and every answer' {
        $cases = @(($script:fixtureText | ConvertFrom-Json -Depth 10).cases)
        $cases.name | Should -Contain 'no state document and a live worker lease'
        $cases.name | Should -Contain 'MIGRATED and an old worker lease'
        @($cases.hold | Sort-Object -Unique) | Should -Be @('endedHold', 'none', 'working')
    }

    It '<Name> -> <Hold>' -ForEach $script:cases {
        $c = @(($script:fixtureText | ConvertFrom-Json -Depth 10).cases | Where-Object name -EQ $Name)[0]
        $lease = WrlLease $c
        InModuleScope VmMigrationFactory -Parameters @{ s = [string]$c.state; l = $lease } {
            Get-VmfMachineHold -State $s -Lease $l
        } | Should -Be $Hold
    }
}

Describe 'WAVE-RUNNING-LEASE-1: the engine''s running rule asks it' {
    BeforeEach { $script:rp = WrlRun }

    It 'a lease on a machine with no state document makes the wave running' {
        WrlPutLease $script:rp $global:WrlA 'w1-worker-0' 30
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp } { Get-VmfWaveRunningDetail -RunPath $p -Wave 'w1' } |
            Should -Be 'vm-a is held by a worker'
    }

    It 'nothing held and nothing at work: not running' {
        WrlState $script:rp $global:WrlA 'MIGRATED'
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp } { Get-VmfWaveRunningDetail -RunPath $p -Wave 'w1' } |
            Should -BeNullOrEmpty
    }

    It 'a stopped worker''s hold on a finished machine keeps the wave running, and says the service removes it' {
        WrlState $script:rp $global:WrlA 'MIGRATED'
        WrlPutLease $script:rp $global:WrlA 'w1-worker-0' 3600
        $said = InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp } { Get-VmfWaveRunningDetail -RunPath $p -Wave 'w1' }
        $said | Should -Be 'vm-a is held by a worker that stopped, and the service removes that hold at its next check'
    }

    It 'a machine at work is named before a stopped worker''s hold: the wave still runs after that hold goes' {
        WrlState $script:rp $global:WrlA 'MIGRATED'
        WrlPutLease $script:rp $global:WrlA 'w1-worker-0' 3600
        WrlState $script:rp $global:WrlB 'CONVERTING'
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp } { Get-VmfWaveRunningDetail -RunPath $p -Wave 'w1' } |
            Should -Be 'vm-b is CONVERTING'
    }

    It 'a live worker lease on a finished machine is still a worker at work' {
        WrlState $script:rp $global:WrlA 'MIGRATED'
        WrlPutLease $script:rp $global:WrlA 'w1-worker-0' 30
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp } { Get-VmfWaveRunningDetail -RunPath $p -Wave 'w1' } |
            Should -Be 'vm-a is held by a worker'
    }

    It 'the hold the service lists for removal is exactly the endedHold of the rule' {
        WrlState $script:rp $global:WrlA 'MIGRATED'
        WrlPutLease $script:rp $global:WrlA 'w1-worker-0' 3600
        WrlState $script:rp $global:WrlB 'MIGRATED'
        WrlPutLease $script:rp $global:WrlB 'restore:op-1' 3600
        $holds = @(InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp } { Get-VmfEndedWaveHolds -RunPath $p })
        $holds.Count | Should -Be 1
        $holds[0].VmId | Should -Be $global:WrlA
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'EndedWaveHold.ps1')
        $lister = $code.Substring($code.IndexOf('function Get-VmfEndedWaveHolds'), $code.IndexOf('function Remove-VmfEndedWaveHold') - $code.IndexOf('function Get-VmfEndedWaveHolds'))
        $lister | Should -Match "Get-VmfMachineHold [^\r\n]*-ne 'endedHold'"
    }
}

Describe 'WAVE-RUNNING-LEASE-1: a lease is a contract' {
    It 'New-VmfLease writes a lease that matches schemas/lease.schema.json' {
        $rp = WrlRun
        InModuleScope VmMigrationFactory -Parameters @{ p = $rp; id = $global:WrlA } { New-VmfLease -RunPath $p -VmId $id -WorkerId 'w1-worker-0' | Out-Null }
        $text = InModuleScope VmMigrationFactory -Parameters @{ p = $rp; id = $global:WrlA } { Read-VmfStoreText -RunPath $p -RelPath (Get-VmfLeaseRelPath -VmId $id) }
        ($text | ConvertFrom-Json).schemaVersion | Should -Be 1
        Test-Json -Json $text -SchemaFile $script:leaseSchema -ErrorAction Stop | Should -BeTrue
    }

    It 'a renewed lease still matches it' {
        $rp = WrlRun
        InModuleScope VmMigrationFactory -Parameters @{ p = $rp; id = $global:WrlA } {
            New-VmfLease -RunPath $p -VmId $id -WorkerId 'w1-worker-0' | Out-Null
            Update-VmfLeaseHeartbeat -RunPath $p -VmId $id -WorkerId 'w1-worker-0'
        }
        $text = InModuleScope VmMigrationFactory -Parameters @{ p = $rp; id = $global:WrlA } { Read-VmfStoreText -RunPath $p -RelPath (Get-VmfLeaseRelPath -VmId $id) }
        Test-Json -Json $text -SchemaFile $script:leaseSchema -ErrorAction Stop | Should -BeTrue
    }

    It 'the schema refuses a lease with no holder' {
        { Test-Json -Json '{"schemaVersion":1,"vmId":"x","acquiredUtc":"2026-11-07T00:00:00Z","heartbeatUtc":"2026-11-07T00:00:00Z"}' -SchemaFile $script:leaseSchema -ErrorAction Stop } |
            Should -Throw
    }
}
