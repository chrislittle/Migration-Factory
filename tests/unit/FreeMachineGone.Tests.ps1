#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# FREE-MACHINE-GONE-1 (2026-10-30). "Free this machine" had no clear purpose,
# and no test run had ever shown it. Before it goes,
# this file proves which AUTOMATIC path frees a machine that is held while
# nothing works on it, and how long that takes.
#
# Two fences hold a machine:
#   the LEASE  (<run>/leases/<key>.lease) fences the workers, restores and
#              rebuilds of ONE migration. A dead holder stops its heartbeat.
#   the CLAIM  (<store>/vmf-claims/<key>.claim) fences MIGRATIONS. It belongs
#              to a run, not to a worker.
# The control removed only the claim. These tests show what frees each one.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    # TEST-AZURE-GUARD-2: every module first, then the guard.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'freegone'

    $script:avset = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-f/providers/Microsoft.Compute/availabilitySets/as-1'
    function Global:NewFreeGonePlan {
        param([int]$Count = 1, [string]$AvSet = '')
        $entries = for ($i = 1; $i -le $Count; $i++) {
            [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-f/providers/Microsoft.Compute/virtualMachines/fvm$i"
                wave = 'w1'; ring = 'lab'; appGroup = "fvm$i"
                assessment = [pscustomobject]@{
                    classification = 'ReadyNow'; gen = 'V2'; os = 'Linux'
                    sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'
                    platformManaged = $false; availabilitySetId = $AvSet
                }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
                path = 'A'
                policy = [pscustomobject]@{ requireApproval = $false }
            }
        }
        [pscustomobject]@{ schemaVersion = 1; entries = @($entries) }
    }
    # A holder that stopped: its heartbeat is set back by the given seconds.
    function Global:AgeFreeGoneLease {
        param([string]$RunPath, [string]$LeaseId, [int]$Seconds)
        & (Get-Module VmMigrationFactory) { param($rp, $id, $s)
            $rel = Get-VmfLeaseRelPath -VmId $id
            $lease = Read-VmfStoreJson -RunPath $rp -RelPath $rel -Depth 6
            $lease.heartbeatUtc = (Get-Date).ToUniversalTime().AddSeconds(-$s).ToString('o')
            Write-VmfStoreJson -RunPath $rp -RelPath $rel -Document $lease -Depth 6
        } $RunPath $LeaseId $Seconds
    }
    function Global:NewFreeGoneRun {
        param([string]$Root, [string]$Name)
        $rp = Join-Path $Root $Name
        & (Get-Module VmMigrationFactory) { param($r, $id) Initialize-VmfRun -RunPath $r -RunId $id | Out-Null } $rp $Name
        $rp
    }
}

AfterAll {
    foreach ($f in 'NewFreeGonePlan', 'AgeFreeGoneLease', 'NewFreeGoneRun', 'Invoke-AzRestMethod') {
        Remove-Item -Path "function:\$f" -ErrorAction SilentlyContinue
    }
    Remove-VmfTestTemp   # TEMP-LITTER-1; throws if anything survives
}

Describe 'FREE-MACHINE-GONE-1: a machine held by a holder that stopped is freed with no person' {
    BeforeEach {
        $script:storeRoot = Join-Path $script:temp "s-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:runA = NewFreeGoneRun -Root $script:storeRoot -Name 'run-a'
    }
    AfterEach { if (Test-Path $script:storeRoot) { Remove-Item $script:storeRoot -Recurse -Force } }

    It 'a worker that stopped mid-step: the watchdog removes its lease after the limit, and another worker of the run takes the machine' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runA } {
            $plan = NewFreeGonePlan -Count 1
            (Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'w1' -WorkerId 'worker-1').Entry | Should -Not -BeNullOrEmpty
            # worker-1 stops here: no release, no heartbeat.
            Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'w1' -WorkerId 'worker-2' | Should -BeNullOrEmpty -Because 'the lease holds it while the heartbeat is young'
            AgeFreeGoneLease -RunPath $rp -LeaseId $plan.entries[0].vmId -Seconds 901
            @(Get-VmfExpiredLeases -RunPath $rp -TimeoutSeconds 900).Count | Should -Be 1
            Remove-VmfExpiredLease -RunPath $rp -VmId $plan.entries[0].vmId -TimeoutSeconds 900 | Should -BeTrue
            $next = Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'w1' -WorkerId 'worker-2'
            $next.Entry.vmId | Should -Be $plan.entries[0].vmId -Because 'the claim belongs to the run, so the run takes its machine again'
        }
    }

    It 'a worker whose heartbeat is younger than the limit keeps its machine' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runA } {
            $plan = NewFreeGonePlan -Count 1
            Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'w1' -WorkerId 'worker-1' | Out-Null
            AgeFreeGoneLease -RunPath $rp -LeaseId $plan.entries[0].vmId -Seconds 600
            @(Get-VmfExpiredLeases -RunPath $rp -TimeoutSeconds 900).Count | Should -Be 0
            Remove-VmfExpiredLease -RunPath $rp -VmId $plan.entries[0].vmId -TimeoutSeconds 900 | Should -BeFalse
            Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'w1' -WorkerId 'worker-2' | Should -BeNullOrEmpty
        }
    }

    It 'the availability set lock of a worker that stopped is a lease too: the watchdog lists it and removes it, and the next member is taken' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runA; avset = $script:avset } {
            $plan = NewFreeGonePlan -Count 2 -AvSet $avset
            $first = Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'w1' -WorkerId 'worker-1'
            $first.GroupLockId | Should -Not -BeNullOrEmpty
            Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'w1' -WorkerId 'worker-2' | Should -BeNullOrEmpty -Because 'one conversion per availability set at a time'
            AgeFreeGoneLease -RunPath $rp -LeaseId $first.Entry.vmId -Seconds 901
            AgeFreeGoneLease -RunPath $rp -LeaseId $first.GroupLockId -Seconds 901
            $expired = @(Get-VmfExpiredLeases -RunPath $rp -TimeoutSeconds 900)
            @($expired.vmId) | Should -Contain $first.GroupLockId -Because 'the watchdog reads every lease in the folder, the set lock included'
            foreach ($e in $expired) { Remove-VmfExpiredLease -RunPath $rp -VmId $e.vmId -TimeoutSeconds 900 | Should -BeTrue }
            (Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'w1' -WorkerId 'worker-2').Entry | Should -Not -BeNullOrEmpty
        }
    }

    It 'a restore that stopped: the next job takes its hold over once it is older than the limit' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runA } {
            $vm = (NewFreeGonePlan -Count 1).entries[0].vmId
            New-VmfLease -RunPath $rp -VmId $vm -WorkerId 'restore:op-dead' | Out-Null
            AgeFreeGoneLease -RunPath $rp -LeaseId $vm -Seconds ($script:VmfMachineLeaseTimeoutSeconds + 1)
            $token = Enter-VmfMachineLease -RunPath $rp -VmId $vm -Holder 'rebuild:op-new' -WarningAction SilentlyContinue
            try { (Get-VmfLeaseInfo -RunPath $rp -VmId $vm).workerId | Should -Be 'rebuild:op-new' }
            finally { Exit-VmfMachineLease -Token $token }
        }
    }

    It 'every judge of a stopped holder uses ONE limit, 900 seconds: the watchdog, the restore hold, the stalled-wave restart and Stop the run' {
        $default = { param($cmd) [string](((Get-Command $cmd).ScriptBlock.Ast.Body.ParamBlock.Parameters |
                    Where-Object { $_.Name.VariablePath.UserPath -eq 'LeaseTimeoutSeconds' }).DefaultValue.Extent.Text) }
        & $default 'Start-VmfWave' | Should -Be '900'
        & $default 'Stop-VmfRun' | Should -Be '900'
        & $default 'Invoke-VmfFacadeResumeStalledWaves' | Should -Be '900'
        (& (Get-Module VmMigrationFactory) { $script:VmfMachineLeaseTimeoutSeconds }) | Should -Be 900
    }

    It 'a run that was deleted: the next migration takes its claim, and the record says from which run' {
        $runB = NewFreeGoneRun -Root $script:storeRoot -Name 'run-b'
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:runA; vm = (NewFreeGonePlan).entries[0].vmId } {
            (New-VmfVmClaim -RunPath $a -VmId $vm -RunId 'run-a').Granted | Should -BeTrue
        }
        Remove-Item $script:runA -Recurse -Force
        InModuleScope VmMigrationFactory -Parameters @{ b = $runB; vm = (NewFreeGonePlan).entries[0].vmId } {
            $r = New-VmfVmClaim -RunPath $b -VmId $vm -RunId 'run-b'
            $r.Granted | Should -BeTrue
            (Get-VmfVmClaim -RunPath $b -VmId $vm).takenBy | Should -Be 'automatic'
        }
    }
}

Describe 'FREE-MACHINE-GONE-1: a claim held by a live run whose workers are all gone' {
    BeforeEach {
        $script:storeRoot = Join-Path $script:temp "s-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:runA = NewFreeGoneRun -Root $script:storeRoot -Name 'run-a'
        $script:runB = NewFreeGoneRun -Root $script:storeRoot -Name 'run-b'
        $script:plan = NewFreeGonePlan -Count 1
        $script:vm = $script:plan.entries[0].vmId
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runA; plan = $script:plan } {
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
            Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'w1' -WorkerId 'worker-1' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'run-a' -VmId $plan.entries[0].vmId -Wave 'w1' | Out-Null
            # worker-1 stops, and the watchdog removes its lease.
            Remove-VmfLease -RunPath $rp -VmId $plan.entries[0].vmId -Force
        }
    }
    AfterEach { if (Test-Path $script:storeRoot) { Remove-Item $script:storeRoot -Recurse -Force } }

    It 'the run that holds the claim takes the machine again at once: its own claim never refuses it' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runA; plan = $script:plan } {
            (Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'w1' -WorkerId 'worker-9').Entry | Should -Not -BeNullOrEmpty
        }
    }

    It 'another migration is refused while the run lives, by the run''s name - the claim is the fence between migrations' {
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; vm = $script:vm } {
            $r = New-VmfVmClaim -RunPath $b -VmId $vm -RunId 'run-b'
            $r.Granted | Should -BeFalse
            $r.HeldBy | Should -Be 'run-a'
        }
    }

    It 'a machine that FAILED and rolled back stays held on purpose, and Skip this machine releases it for another migration' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runA; vm = $script:vm } {
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'FAILED_ROLLED_BACK' -Outcome fail -Detail 'rolled back' | Out-Null
        }
        Skip-VmfVm -RunPath $script:runA -VmId $script:vm -Reason 'migrating it later' -SkippedBy 'operator@example.com' -Confirm:$false | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; vm = $script:vm } {
            (New-VmfVmClaim -RunPath $b -VmId $vm -RunId 'run-b').Granted | Should -BeTrue
        }
    }

    It 'a machine that MIGRATED but kept its claim (the execution stopped before the end of its wave) is released by Stop the run' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runA; vm = $script:vm } {
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'MIGRATED' -Outcome ok -Detail 'done' | Out-Null
        }
        Stop-VmfRun -RunPath $script:runA -Reason 'closing the run out' -StoppedBy 'operator@example.com' -Confirm:$false | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ b = $script:runB; vm = $script:vm } {
            (New-VmfVmClaim -RunPath $b -VmId $vm -RunId 'run-b').Granted | Should -BeTrue
        }
    }

    # The control this item removes freed the claim and never the lease: proved
    # by a test here at commit 6375a3bf, before the command was removed. What a
    # person uses instead, in the app, is Skip this machine and Stop the run
    # (above), and the claim of a deleted run goes by itself.
}

Describe 'FREE-MACHINE-GONE-1: nothing in the product removes a claim by hand' {
    It 'the module has no command that releases another run''s claim' {
        Get-Command -Module VmMigrationFactory -Name 'Clear-VmfVmClaim' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $manifest = Import-PowerShellDataFile (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1')
        @($manifest.FunctionsToExport) | Should -Not -Contain 'Clear-VmfVmClaim'
        Test-Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Clear-VmfVmClaim.ps1') | Should -BeFalse
    }

    It 'the service has no function and no endpoint for it - found by route, not by name' {
        Get-Command -Module FacadeCore -Name 'Invoke-VmfFacadeClearClaim' -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        $facadeManifest = Import-PowerShellDataFile (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1')
        @($facadeManifest.FunctionsToExport) | Should -Not -Contain 'Invoke-VmfFacadeClearClaim'
        $routes = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'facade' 'app') -Recurse -Filter 'function.json' |
            ForEach-Object { @((Get-Content $_.FullName -Raw | ConvertFrom-Json).bindings) | Where-Object { $_.route } | ForEach-Object { [string]$_.route } })
        $routes.Count | Should -BeGreaterThan 10 -Because 'the check must read the real routes'
        @($routes | Where-Object { $_ -match '(?i)claim' }) | Should -BeNullOrEmpty
    }

    It 'no dashboard page calls a claim route or shows the control' {
        foreach ($page in Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Recurse -Include '*.html', '*.js') {
            $code = Get-VmfCodeOnly -Path $page.FullName
            $code | Should -Not -Match 'claim/clear' -Because $page.Name
            $code | Should -Not -Match 'free-btn|askFreeMachine' -Because $page.Name
        }
    }
}