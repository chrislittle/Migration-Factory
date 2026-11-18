#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TEST-SEAM-HARDEN-1. worker.ps1 has two test hooks: VMF_TEST_ENGINE runs the
# script its value names in place of the state machine, and
# VMF_TEST_AZURE_GUARD loads tests/unit/_AzureGuard.ps1. Neither refused when
# the worker ran in the hosted engine.
#
# The marker is one the product already reads: a managed identity endpoint in
# the environment (IDENTITY_ENDPOINT, or MSI_SECRET on an older host). The
# Container Apps platform sets it in the engine job, the engine's sign-in
# (Connect-AzAccount -Identity in docker/entrypoint.ps1) needs it, and the
# facade's profile.ps1 already decides "this runs in Azure" on the same two
# values. A developer machine and the CI runners have neither.
#
# The rules held here:
#   - with the marker, a worker given either hook takes no machine, runs no
#     test script, loads no guard, exits non-zero, and says why on stderr and
#     in the run history;
#   - each half of the marker is enough;
#   - the marker alone refuses nothing;
#   - without the marker, both hooks still work (the unit tests use them).

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:workerScript = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Workers' 'worker.ps1'
    $script:seamNames = 'IDENTITY_ENDPOINT', 'MSI_SECRET', 'VMF_TEST_ENGINE', 'VMF_TEST_AZURE_GUARD'

    # One real worker process over a file store. The fake engine writes a file
    # when it runs, so a test sees whether the hook ran. $Wave 'w1' holds one
    # machine; 'empty' holds none, so a worker with no fake engine never
    # reaches the state machine.
    function script:Invoke-TshWorker {
        param([hashtable]$Environment, [string]$Wave = 'w1')
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-tsh-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $root | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $root } { Initialize-VmfRun -RunPath $rp -RunId 'tsh-run' | Out-Null }
        $planFile = Join-Path $root 'plan.json'
        @{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion)
                    vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-t/providers/Microsoft.Compute/virtualMachines/tsh1'
                    wave = 'w1'; path = 'A'; assessment = [ordered]@{ location = 'centralus'; availabilitySetId = '' }
                    target = [ordered]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; policy = [ordered]@{ requireApproval = $true } })
        } | ConvertTo-Json -Depth 12 | Set-Content $planFile
        $ranFile = Join-Path $root 'fake-engine-ran.txt'
        $fake = Join-Path $root 'fake-engine.ps1'
        @'
param($EntryJson, $RunPath, $RunId)
$entry = $EntryJson | ConvertFrom-Json -Depth 24
Set-Content (Join-Path $RunPath 'fake-engine-ran.txt') 'ran'
& (Get-Module VmMigrationFactory) { param($id, $rp, $rid)
    New-VmfStateDoc -RunPath $rp -RunId $rid -VmId $id | Out-Null
    Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok | Out-Null
} $entry.vmId $RunPath $RunId
'@ | Set-Content $fake

        $before = @{}
        foreach ($n in $script:seamNames) { $before[$n] = [Environment]::GetEnvironmentVariable($n) }
        try {
            foreach ($n in $script:seamNames) { [Environment]::SetEnvironmentVariable($n, $null) }
            foreach ($k in $Environment.Keys) {
                $v = if ($Environment[$k] -eq 'FAKE') { $fake } else { $Environment[$k] }
                [Environment]::SetEnvironmentVariable($k, $v)
            }
            $out = & (Get-Process -Id $PID).Path -NoProfile -File $script:workerScript -RunPath $root -PlanPath $planFile -Wave $Wave `
                -RunId 'tsh-run' -WorkerId 'worker-tsh' -IdleWaitSeconds 1 2>&1 | Out-String
            $code = $LASTEXITCODE
        }
        finally {
            foreach ($n in $script:seamNames) { [Environment]::SetEnvironmentVariable($n, $before[$n]) }
        }
        $events = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $root } { Read-VmfEvents -RunPath $rp -Step 'worker' })
        [pscustomobject]@{
            Root     = $root
            Out      = $out
            Code     = $code
            Ran      = Test-Path $ranFile
            States   = @(Get-ChildItem (Join-Path $root 'state') -Filter *.json -ErrorAction SilentlyContinue).Count
            Refusals = @($events | Where-Object { $_.outcome -eq 'refused' })
        }
    }
}

Describe 'TEST-SEAM-HARDEN-1: in the hosted engine, the worker refuses its test hooks' {
    AfterEach { if ($script:r -and (Test-Path $script:r.Root)) { Remove-Item $script:r.Root -Recurse -Force } }

    It 'VMF_TEST_ENGINE with IDENTITY_ENDPOINT: the test script does not run, no machine is taken, and the worker says why' {
        $script:r = Invoke-TshWorker @{ IDENTITY_ENDPOINT = 'http://localhost:42356/msi/token'; VMF_TEST_ENGINE = 'FAKE' }
        $script:r.Ran | Should -BeFalse -Because $script:r.Out
        $script:r.States | Should -Be 0
        $script:r.Code | Should -Be 4 -Because $script:r.Out
        $script:r.Out | Should -Match 'runs in the hosted engine'
        $script:r.Out | Should -Match 'VMF_TEST_ENGINE'
        $script:r.Refusals.Count | Should -Be 1
        $script:r.Refusals[0].detail | Should -Match 'worker-tsh runs in the hosted engine.*VMF_TEST_ENGINE.*took no machine'
        @(Get-ChildItem (Join-Path $script:r.Root 'leases') -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'VMF_TEST_ENGINE with MSI_SECRET alone: the same refusal' {
        $script:r = Invoke-TshWorker @{ MSI_SECRET = 'not-a-secret'; VMF_TEST_ENGINE = 'FAKE' }
        $script:r.Ran | Should -BeFalse -Because $script:r.Out
        $script:r.Code | Should -Be 4 -Because $script:r.Out
        $script:r.Refusals.Count | Should -Be 1
    }

    It 'VMF_TEST_AZURE_GUARD with IDENTITY_ENDPOINT: the guard does not load, and the worker says why' {
        $script:r = Invoke-TshWorker @{ IDENTITY_ENDPOINT = 'http://localhost:42356/msi/token'; VMF_TEST_AZURE_GUARD = '1' } -Wave 'empty'
        $script:r.Out | Should -Not -Match 'test Azure guard on'
        $script:r.Code | Should -Be 4 -Because $script:r.Out
        $script:r.Out | Should -Match 'VMF_TEST_AZURE_GUARD'
        $script:r.Refusals.Count | Should -Be 1
        $script:r.Refusals[0].detail | Should -Match 'VMF_TEST_AZURE_GUARD'
    }

    It 'VMF_TEST_AZURE_GUARD with MSI_SECRET alone: the same refusal' {
        $script:r = Invoke-TshWorker @{ MSI_SECRET = 'not-a-secret'; VMF_TEST_AZURE_GUARD = '1' } -Wave 'empty'
        $script:r.Out | Should -Not -Match 'test Azure guard on'
        $script:r.Code | Should -Be 4 -Because $script:r.Out
    }

    It 'the marker alone refuses nothing: a hosted worker with no test value works as before' {
        $script:r = Invoke-TshWorker @{ IDENTITY_ENDPOINT = 'http://localhost:42356/msi/token' } -Wave 'empty'
        $script:r.Code | Should -Be 0 -Because $script:r.Out
        $script:r.Refusals.Count | Should -Be 0
        $script:r.Out | Should -Match 'no more leasable work'
    }
}

Describe 'TEST-SEAM-HARDEN-1: with no marker, the test hooks still work' {
    AfterEach { if ($script:r -and (Test-Path $script:r.Root)) { Remove-Item $script:r.Root -Recurse -Force } }

    It 'VMF_TEST_ENGINE runs the test script in place of the state machine' {
        $script:r = Invoke-TshWorker @{ VMF_TEST_ENGINE = 'FAKE' }
        $script:r.Ran | Should -BeTrue -Because $script:r.Out
        $script:r.Code | Should -Be 0 -Because $script:r.Out
        $script:r.Refusals.Count | Should -Be 0
    }

    It 'VMF_TEST_AZURE_GUARD loads the guard' {
        $script:r = Invoke-TshWorker @{ VMF_TEST_AZURE_GUARD = '1' } -Wave 'empty'
        $script:r.Out | Should -Match 'test Azure guard on'
        $script:r.Code | Should -Be 0 -Because $script:r.Out
    }

    # FACADE-SIGNIN-COLD-1: the facade no longer signs in, so its start-up
    # script no longer reads the marker; the engine sign-in still needs the
    # managed identity endpoint the marker names.
    It 'the marker is the one the engine sign-in needs' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') | Should -Match 'Connect-AzAccount -Identity'
        Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Workers' 'worker.ps1') |
            Should -Match '\$env:IDENTITY_ENDPOINT -or \$env:MSI_SECRET'
    }
}
