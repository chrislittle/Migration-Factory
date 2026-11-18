#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SCALE-UX-1: the engine measures what its workers weigh, where they run.
#
# The sizing table's per-worker budget rested on a local idle measurement.
# This is the instrument that replaces it: the orchestrator samples its worker
# processes and writes the reading into the run's activity log. The sampler
# is pure over process-shaped objects, so it is tested here with fakes; the
# container total comes from the cgroup files, so it is tested with a
# temporary directory standing in for /sys/fs/cgroup.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    function Global:FakeWorker { param([long]$Bytes, [bool]$Exited = $false) [pscustomobject]@{ WorkingSet64 = $Bytes; HasExited = $Exited } }
    $script:cg = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-cg-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $script:cg -Force | Out-Null
}
AfterAll {
    Remove-Item 'function:\FakeWorker' -ErrorAction SilentlyContinue
    if (Test-Path $script:cg) { Remove-Item $script:cg -Recurse -Force }
}

Describe 'SCALE-UX-1: Get-VmfWorkerMemorySample' {

    It 'reads the live workers and ignores the exited ones' {
        $workers = @((FakeWorker 200MB), (FakeWorker 300MB), (FakeWorker 900MB -Exited $true))
        $s = InModuleScope VmMigrationFactory -Parameters @{ w = $workers; cg = $script:cg } { Get-VmfWorkerMemorySample -Workers $w -CgroupRoot $cg }
        $s.alive | Should -Be 2
        $s.minMB | Should -Be 200
        $s.avgMB | Should -Be 250
        $s.maxMB | Should -Be 300
    }

    It 'says nothing about the container where there is no cgroup, rather than inventing a number' {
        $s = InModuleScope VmMigrationFactory -Parameters @{ w = @((FakeWorker 100MB)); cg = $script:cg } { Get-VmfWorkerMemorySample -Workers $w -CgroupRoot $cg }
        $s.containerMB | Should -BeNullOrEmpty
        $s.cgroup | Should -BeNullOrEmpty
    }

    It 'reads the container total from cgroup v2 when present, v1 otherwise' {
        New-Item -ItemType Directory -Path (Join-Path $script:cg 'memory') -Force | Out-Null
        Set-Content (Join-Path $script:cg 'memory' 'memory.usage_in_bytes') -Value ([string](1500MB)) -NoNewline
        $v1 = InModuleScope VmMigrationFactory -Parameters @{ cg = $script:cg } { Get-VmfWorkerMemorySample -Workers @() -CgroupRoot $cg }
        $v1.cgroup | Should -Be 'v1'
        $v1.containerMB | Should -Be 1500
        Set-Content (Join-Path $script:cg 'memory.current') -Value ([string](2200MB)) -NoNewline
        $v2 = InModuleScope VmMigrationFactory -Parameters @{ cg = $script:cg } { Get-VmfWorkerMemorySample -Workers @() -CgroupRoot $cg }
        $v2.cgroup | Should -Be 'v2' -Because 'v2 wins when both exist'
        $v2.containerMB | Should -Be 2200
    }

    It 'with no workers at all reports zero, not an error' {
        $s = InModuleScope VmMigrationFactory -Parameters @{ cg = $script:cg } { Get-VmfWorkerMemorySample -Workers $null -CgroupRoot $cg }
        $s.alive | Should -Be 0
        $s.maxMB | Should -Be 0
    }
}

Describe 'SCALE-UX-1: Update-VmfMemoryPeak keeps the number the sizing table needs' {

    It 'folds samples into the peak per worker and per container, and remembers how many workers were alive at it' {
        $peak = InModuleScope VmMigrationFactory {
            $p = $null
            $p = Update-VmfMemoryPeak -Peak $p -Sample ([pscustomobject]@{ alive = 3; maxMB = 210; containerMB = 900 })
            $p = Update-VmfMemoryPeak -Peak $p -Sample ([pscustomobject]@{ alive = 10; maxMB = 340; containerMB = 2600 })
            $p = Update-VmfMemoryPeak -Peak $p -Sample ([pscustomobject]@{ alive = 4; maxMB = 300; containerMB = $null })
            $p
        }
        $peak.workerMB | Should -Be 340
        $peak.workersAtPeak | Should -Be 10
        $peak.containerMB | Should -Be 2600
        $peak.samples | Should -Be 3
    }
}

Describe 'SCALE-UX-1: the orchestrator writes what it saw' {
    BeforeAll { $script:wave = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1') -Raw }

    It 'samples every pass and records a reading about once a minute' {
        $script:wave | Should -Match 'Get-VmfWorkerMemorySample -Workers \$workers'
        $script:wave | Should -Match "Step 'engine:memory'"
        $script:wave | Should -Match 'Update-VmfMemoryPeak'
    }

    It 'and writes the peak at the end, with the worker count it was seen at' {
        $script:wave | Should -Match 'Peak memory'
        $script:wave | Should -Match 'workersAtPeak'
    }
}
