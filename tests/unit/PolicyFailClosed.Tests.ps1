#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# OLD-VERSION-READERS-REMOVE-3, hardening (security pass finding): every policy
# value the engine reads from a plan entry fails closed.
#
# The temporary disk check read onDDataFound and treated any value other than
# 'stop' as proceed - so a value no writer gives ('Stop ', 'continue', a value
# an earlier version wrote) moved a machine with data on its temporary disk.
# The rule now: a value the plan-entry contract does not list takes the SAFE
# choice. PRECHECK refuses the machine, untouched, before the first Azure call
# (policyNotKnown), and the acceptance of its wave is refused. Each read that
# can run later, on a resume, takes the safe side on its own as well.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    $script:sub = '00000000-0000-0000-0000-000000000000'
    function Global:PfcEntry {
        param([hashtable]$Policy = @{}, [string]$Name = 'pfcvm', [string]$Os = 'Linux', [string]$Arch = 'diskless')
        $pol = [ordered]@{ safetyCopy = 'pristine'; capacityGate = 'BestEffort' }
        foreach ($k in $Policy.Keys) { $pol[$k] = $Policy[$k] }
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion)
            vmId = "/subscriptions/$script:sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$Name"
            wave = 'w1'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                                            blockers = @(); prepNeeded = @(); platformManaged = $false
                                            sourceSize = 'Standard_D2s_v4'; sourceDiskArch = $Arch }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
            path = 'A'
            policy = [pscustomobject]$pol
        }
    }
    # Each setting the engine reads from a plan entry, with every value a
    # writer of this version gives, and values no writer gives.
    $script:cases = @(
        @{ Name = 'capacityGate';          Good = @('BestEffort', 'Reserved');          Bad = @('reserved ', 'None', 'besteffort', '', 1) }
        @{ Name = 'onDDataFound';          Good = @('stop', 'proceed');                Bad = @('Proceed', 'continue', 'park', 'Stop ', '') }
        @{ Name = 'onDriverBelowFloor';    Good = @('stop', 'updateKernel');           Bad = @('proceed', 'park', 'UpdateKernel', '') }
        @{ Name = 'acceleratedNetworking'; Good = @('ensureOn', 'preserve');           Bad = @('ensureOff', 'on', 'EnsureOn', '') }
        # VF-UNMANAGED-CONFIG-1 (v34): an approver's decision for one machine.
        @{ Name = 'onSriovUnmanagedMissing'; Good = @('stop', 'proceed');            Bad = @('Proceed', 'continue', 'proceed ', '') }
        @{ Name = 'targetGeneration';      Good = @('v5', 'v6', 'v7');                 Bad = @('v4', 'v8', 'V6', '') }
        @{ Name = 'diskUpgrade';           Good = @('os', 'all', 'os-standard-ssd');   Bad = @('premium', 'OS', 'none', '') }
        @{ Name = 'throttle';              Good = @(5, 15, 30, 60);                    Bad = @(0, 1, 7, 61, -1, 'x', 2.5, '15') }   # ATONCE-EARLIER-1
        @{ Name = 'keepSnapshotDays';      Good = @(0, 7, 90);                         Bad = @(-1, 91, 'x', 1.5, '7') }
        @{ Name = 'requireApproval';       Good = @($true, $false);                    Bad = @('false', 0, 1, 'no') }
        # MANUAL-REVIEW-1: safetyCopy is held by this rule too; bootableClone is gone.
        @{ Name = 'safetyCopy';            Good = @('pristine');                       Bad = @('clean', 'Pristine', 'none', '') }
    )
}
AfterAll { Remove-Item 'function:\PfcEntry' -ErrorAction SilentlyContinue }

Describe 'OLD-VERSION-READERS-REMOVE-3: one rule says which stored policy values the engine acts on' {
    It 'an entry with no policy value, or a null value, takes the engine default and is not refused' {
        InModuleScope VmMigrationFactory -Parameters @{ cases = $script:cases } {
            param($cases)
            $cases.Count | Should -Be 11
            Get-VmfPlanPolicyRefusal -PlanEntry (Global:PfcEntry) | Should -BeNullOrEmpty
            foreach ($c in $cases) {
                Get-VmfPlanPolicyRefusal -PlanEntry (Global:PfcEntry -Policy @{ $c.Name = $null }) |
                    Should -BeNullOrEmpty -Because "a null $($c.Name) is the default"
            }
        }
    }

    It 'every value a writer of this version gives is accepted' {
        InModuleScope VmMigrationFactory -Parameters @{ cases = $script:cases } {
            param($cases)
            $cases.Count | Should -Be 11
            foreach ($c in $cases) {
                foreach ($v in $c.Good) {
                    Get-VmfPlanPolicyRefusal -PlanEntry (Global:PfcEntry -Policy @{ $c.Name = $v }) |
                        Should -BeNullOrEmpty -Because "$($c.Name) = '$v' is a value this version writes"
                }
            }
        }
    }

    It 'every other value is refused, and the refusal names the setting and the value' {
        InModuleScope VmMigrationFactory -Parameters @{ cases = $script:cases } {
            param($cases)
            $cases.Count | Should -Be 11
            foreach ($c in $cases) {
                foreach ($v in $c.Bad) {
                    $why = Get-VmfPlanPolicyRefusal -PlanEntry (Global:PfcEntry -Policy @{ $c.Name = $v })
                    $why | Should -Not -BeNullOrEmpty -Because "$($c.Name) = '$v' is not a value this version writes"
                    $why | Should -Match ([regex]::Escape("'$($c.Name)'"))
                }
            }
        }
    }

    It 'reads a plan entry held as a hashtable the same way' {
        InModuleScope VmMigrationFactory {
            Get-VmfPlanPolicyRefusal -PlanEntry @{ policy = @{ onDDataFound = 'continue' } } | Should -Match "'onDDataFound'"
            Get-VmfPlanPolicyRefusal -PlanEntry @{ policy = @{ onDDataFound = 'stop' } } | Should -BeNullOrEmpty
        }
    }

    It 'the table of values is the plan-entry contract''s, value for value' {
        $schema = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json')) | ConvertFrom-Json -AsHashtable -Depth 40
        $table = InModuleScope VmMigrationFactory { Get-VmfStoredPolicyValues }
        foreach ($name in @($table.Keys)) {
            $prop = $schema.properties.policy.properties[$name]
            $prop | Should -Not -BeNullOrEmpty -Because "$name is in the contract"
            $kind = $table[$name]
            if ($kind -is [string] -and $kind -eq 'bool') { $prop.type | Should -Be 'boolean' }
            elseif ($kind -is [hashtable]) {
                $prop.type | Should -Be 'integer'
                if ($kind.ContainsKey('Values')) { @($prop.enum) | Should -Be @($kind.Values) -Because "$name lists the same choices" }
                else {
                    $prop.minimum | Should -Be $kind.Min
                    $prop.maximum | Should -Be $kind.Max
                }
            }
            else { @($prop.enum | Sort-Object) | Should -Be @(@($kind) | Sort-Object) -Because "$name lists the same values" }
        }
        foreach ($name in @($schema.properties.policy.properties.Keys)) {
            $table.Keys | Should -Contain $name -Because "the engine reads $name, so the rule checks it"
        }
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-3: PRECHECK refuses a policy value it does not know, before anything touches the machine' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { throw 'reached the permissions read' }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'must not stop the machine' }
    }

    It 'each setting with a value no writer gives stops the machine with policyNotKnown, untouched' {
        foreach ($c in $script:cases) {
            $entry = PfcEntry -Policy @{ $c.Name = $c.Bad[0] }
            $ctx = @{ Plan = $entry; SubscriptionId = $script:sub; VmId = $entry.vmId; RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-pfc-precheck') }
            $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepPrecheck -Context $ctx }
            $r.Next | Should -Be 'NEEDS_DECISION' -Because "$($c.Name) = '$($c.Bad[0])'"
            $r.Reason | Should -Be 'policyNotKnown'
            $r.MachineState | Should -Be 'untouched'
            $r.Detail | Should -Match ([regex]::Escape("'$($c.Name)'"))
        }
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 0
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0
    }

    It 'known values go on to the next check' {
        $entry = PfcEntry -Policy @{ onDDataFound = 'proceed'; onDriverBelowFloor = 'stop'; acceleratedNetworking = 'ensureOn'; throttle = 15; keepSnapshotDays = 7; requireApproval = $true }
        $ctx = @{ Plan = $entry; SubscriptionId = $script:sub; VmId = $entry.vmId; RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-pfc-precheck') }
        { InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Invoke-VmfStepPrecheck -Context $ctx } } |
            Should -Throw '*reached the permissions read*'
    }

    It 'the stop has guidance: untouched, plan again, no retry' {
        InModuleScope VmMigrationFactory {
            $g = Get-VmfStopGuidance -Code 'policyNotKnown'
            $g | Should -Not -BeNullOrEmpty
            $g.machine | Should -Be 'untouched'
            $g.whatToDo | Should -Match '(?i)plan'
            $g.retry | Should -Be 'notSupported'
        }
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-3: each later read takes the safe side on its own' {
    It 'the temporary disk check goes on only for exactly proceed; any other value stops on data' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { [pscustomobject]@{ result = 'PASS'; warnings = @('file.txt') } }
        foreach ($v in @('stop', 'Proceed', 'continue', 'park', '', 'proceed ')) {
            $ctx = @{ Plan = (PfcEntry -Os 'Windows' -Arch 'scsi-temp' -Policy @{ onDDataFound = $v }); Rg = 'rg'; VmName = 'pfcvm'; VmId = 'x'; RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-pfc-temp') }
            $r = InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Get-VmfTempDiskContentStop -Context $ctx }
            $r.Reason | Should -Be 'dataOnTempDrive' -Because "onDDataFound = '$v' is not proceed"
        }
        $ctx = @{ Plan = (PfcEntry -Os 'Windows' -Arch 'scsi-temp' -Policy @{ onDDataFound = 'proceed' }); Rg = 'rg'; VmName = 'pfcvm'; VmId = 'x'; RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-pfc-temp') }
        InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Get-VmfTempDiskContentStop -Context $ctx } | Should -BeNullOrEmpty
        # No value is the default, which is stop.
        $ctx = @{ Plan = (PfcEntry -Os 'Windows' -Arch 'scsi-temp'); Rg = 'rg'; VmName = 'pfcvm'; VmId = 'x'; RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-pfc-temp') }
        (InModuleScope VmMigrationFactory -Parameters @{ ctx = $ctx } { param($ctx) Get-VmfTempDiskContentStop -Context $ctx }).Reason | Should -Be 'dataOnTempDrive'
    }

    It 'the capacity gate is BestEffort only when the plan says exactly that, or says nothing' {
        InModuleScope VmMigrationFactory {
            Get-VmfCapacityGate -PlanEntry (Global:PfcEntry -Policy @{ capacityGate = 'BestEffort' }) | Should -Be 'BestEffort'
            Get-VmfCapacityGate -PlanEntry (Global:PfcEntry -Policy @{ capacityGate = $null }) | Should -Be 'BestEffort'
            Get-VmfCapacityGate -PlanEntry ([pscustomobject]@{ policy = [pscustomobject]@{} }) | Should -Be 'BestEffort'
            foreach ($v in @('Reserved', 'reserved', 'besteffort', 'None', 'x')) {
                Get-VmfCapacityGate -PlanEntry (Global:PfcEntry -Policy @{ capacityGate = $v }) | Should -Be 'Reserved' -Because "'$v' is not BestEffort"
            }
        }
    }

    It 'the wave start, the reservation check and the quota check read the gate through that one rule' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $start = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1')
        $start | Should -Match 'Get-VmfCapacityGate -PlanEntry'
        $start | Should -Not -Match '\.policy\.capacityGate'
        $move = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'ReservationMove.ps1')
        $move | Should -Match 'Get-VmfCapacityGate -PlanEntry'
        $move | Should -Not -Match '\.policy\.capacityGate'
        # The quota check counts a machine of a Reserved wave as reserved.
        $quota = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Test-VmfQuota.ps1')
        $quota | Should -Match 'Get-VmfCapacityGate -PlanEntry \$member'
        $quota | Should -Not -Match '\.policy\.capacityGate'
    }

    It 'the kernel floor stops on every value but updateKernel' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $code | Should -Match ([regex]::Escape("`$updateKernel = [string]::Equals([string]`$floorPolicy, 'updateKernel', [System.StringComparison]::Ordinal)"))
        $code | Should -Match ([regex]::Escape("`$driverVerdict.Status -eq 'FAIL' -and -not `$updateKernel"))
        $code | Should -Match ([regex]::Escape("if (`$updateKernel -and ("))
        $code | Should -Not -Match "floorPolicy -(c|i)?(eq|ne) "
    }

    It 'a value of keepSnapshotDays the engine cannot read never deletes a copy' {
        InModuleScope VmMigrationFactory {
            foreach ($v in @(-1, 'x', 'seven')) {
                Get-VmfRetentionDays -PlanEntry (Global:PfcEntry -Policy @{ keepSnapshotDays = $v }) | Should -BeNullOrEmpty -Because "'$v' is not a number of days"
            }
        }
    }

    It 'a sign-off value that is not a boolean false reads as required' {
        InModuleScope VmMigrationFactory {
            foreach ($v in @('false', 0, $null, '', 'no')) {
                Test-VmfApprovalRequired -PlanEntry (Global:PfcEntry -Policy @{ requireApproval = $v }) | Should -BeTrue -Because "'$v' is not false"
            }
            Test-VmfApprovalRequired -PlanEntry (Global:PfcEntry -Policy @{ requireApproval = $false }) | Should -BeFalse
        }
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-3: a person cannot accept a wave that holds such a value' {
    It 'the acceptance is refused, names the machine, and writes nothing' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pfc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $plan = [pscustomobject]@{ schemaVersion = 5; assessmentRunId = 'scan-1'
                entries = @((PfcEntry -Name 'okvm'), (PfcEntry -Name 'oddvm' -Policy @{ onDDataFound = 'continue' })) }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; plan = $plan } {
                param($rp, $plan)
                Initialize-VmfRun -RunPath $rp -RunId 'pfc-test' | Out-Null
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
                { Confirm-VmfWaveOptions -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Wave 'w1' -AcceptedBy 'operator@example.com' } |
                    Should -Throw '*oddvm*'
                Read-VmfStoreJson -RunPath $rp -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave 'w1') | Should -BeNullOrEmpty
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-3: a decision stores a count as a whole number' {
    It 'keepSnapshotDays sent as text is stored as a number, so PRECHECK never stops a value a decision wrote' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pfc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $vm = "/subscriptions/$script:sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/pfcdec"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; vm = $vm } {
                param($rp, $vm)
                Initialize-VmfRun -RunPath $rp -RunId 'pfc-dec' | Out-Null
                New-VmfStateDoc -RunPath $rp -RunId 'pfc-dec' -VmId $vm -Wave 'w1' | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'FAILED_ROLLED_BACK' -Outcome fail -ReasonCode 'bootFailedAfterConversion' `
                    -MachineState 'restored' -Detail 'STARTING failed; the machine was rolled back.' | Out-Null
            }
            $pp = Join-Path $rp 'plan.json'
            [ordered]@{ schemaVersion = 5; assessmentRunId = 'pfc-dec'; entries = @(
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'w1'; path = 'A'
                            policy = [ordered]@{ requireApproval = $false; onDDataFound = 'stop'; keepSnapshotDays = 7 } }) } |
                ConvertTo-Json -Depth 10 | Set-Content $pp -Encoding utf8NoBOM
            Confirm-VmfRunAcknowledgement -RunPath $rp -AcknowledgedBy 'operator@example.com' | Out-Null
            Confirm-VmfWaveOptions -RunPath $rp -PlanPath $pp -Wave 'w1' -AcceptedBy 'operator@example.com' -Note 'reviewed' -Confirm:$false | Out-Null
            Resolve-VmfDecision -RunPath $rp -PlanPath $pp -VmId $vm -Note 'keep the copies longer' -ResolvedBy 'operator@example.com' `
                -PolicyOverride @{ keepSnapshotDays = '30' } | Out-Null
            $entry = @((Get-Content $pp -Raw | ConvertFrom-Json -Depth 20).entries)[0]
            $entry.policy.keepSnapshotDays | Should -Be 30
            ($entry.policy.keepSnapshotDays -is [long] -or $entry.policy.keepSnapshotDays -is [int]) | Should -BeTrue -Because 'a count is stored as a number'
            InModuleScope VmMigrationFactory -Parameters @{ e = $entry } { param($e) Get-VmfPlanPolicyRefusal -PlanEntry $e } | Should -BeNullOrEmpty
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
