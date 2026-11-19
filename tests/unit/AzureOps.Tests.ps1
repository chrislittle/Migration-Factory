#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')

    # Az cmdlets are not installed in CI; define global stubs so Pester can mock them.
    function Global:Get-AzVM { param($ResourceGroupName, $Name, [switch]$Status) throw 'stub' }
    function Global:Stop-AzVM { param($ResourceGroupName, $Name, [switch]$Force) throw 'stub' }
    function Global:Get-AzDisk { param($ResourceGroupName, $DiskName) throw 'stub' }
    function Global:Update-AzDisk { throw 'stub' }
    function Global:Get-AzComputeResourceSku { param($Location) throw 'stub' }
    function Global:Get-AzCapacityReservation { param($ResourceGroupName, $ReservationGroupName, $Name) throw 'stub' }
    function Global:Update-AzVM { param($ResourceGroupName, $VM, $CapacityReservationGroupId) throw 'stub' }
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'stub' }
    function Global:Remove-AzCapacityReservation { param($ResourceGroupName, $ReservationGroupName, $Name) throw 'stub' }
    function Global:Remove-AzCapacityReservationGroup { param($ResourceGroupName, $Name) throw 'stub' }
    # TEST-AZURE-GUARD-1: the guard comes AFTER the stand-ins above, so its mocks and this file's own take the same shape.
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # ODCR-SUB-1: capacity calls pin themselves to a subscription context.
    Mock -ModuleName VmMigrationFactory Get-VmfAzContextForSubscription { [pscustomobject]@{ Name = 'test-ctx' } }
}

AfterAll {
    Remove-Item -Path 'function:\Get-AzVM', 'function:\Stop-AzVM', 'function:\Get-AzDisk',
        'function:\Update-AzDisk', 'function:\Get-AzComputeResourceSku',
        'function:\Get-AzCapacityReservation', 'function:\Remove-AzCapacityReservation',
        'function:\Remove-AzCapacityReservationGroup', 'function:\Update-AzVM',
        'function:\Invoke-AzRestMethod' -ErrorAction SilentlyContinue
}

Describe 'azureops Az-cmdlet parameter contract' {
    # REH-1 found Remove-AzCapacityReservation -Force failing at runtime: mocks
    # accept ANY parameters, so a misspelled/nonexistent Az parameter survives
    # unit tests and dies on real Azure. This test validates every literal
    # -Parameter used on an Az* call in azureops against the INSTALLED module
    # metadata. Skips per-cmdlet when Az isn't installed (CI has only stubs -
    # the contract bites on dev machines, where lab drills run).
    It 'every Az* call in azureops uses only parameters the installed cmdlet exposes' {
        $azureopsDir = Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'Private' 'azureops'
        $violations = [System.Collections.Generic.List[string]]::new()
        $checked = 0
        foreach ($file in Get-ChildItem $azureopsDir -Filter '*.ps1') {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null)
            $calls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) |
                Where-Object { $_.GetCommandName() -match '^\w+-Az[A-Z]' }
            foreach ($call in $calls) {
                $name = $call.GetCommandName()
                $cmd = Get-Command $name -ErrorAction SilentlyContinue
                if (-not $cmd -or $cmd.CommandType -eq 'Function') { continue }   # Az absent or stubbed
                $checked++
                $params = $call.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] }
                foreach ($p in $params) {
                    # exact or unambiguous-prefix match, PowerShell binding semantics
                    $paramMatches = @($cmd.Parameters.Keys | Where-Object { $_ -like "$($p.ParameterName)*" })
                    if ($paramMatches.Count -eq 0) {
                        $violations.Add("$($file.Name):$($p.Extent.StartLineNumber) $name -$($p.ParameterName)")
                    }
                }
            }
        }
        if ($checked -eq 0) { Set-ItResult -Skipped -Because 'Az modules not installed (CI)' }
        $violations -join '; ' | Should -BeNullOrEmpty
    }
}

Describe 'module error semantics (REH-1: preference inheritance breaks at module boundaries)' {
    # The rehearsal recorded a claim as RELEASED although the Azure delete
    # 409'd: the caller's $ErrorActionPreference = 'Stop' does NOT cross the
    # module boundary, so the Az cmdlet's non-terminating error printed and
    # execution continued to the success bookkeeping. The module must pin
    # Stop in its own session state - a failed Az call is never a success.
    It 'module session state runs with ErrorActionPreference Stop' {
        InModuleScope VmMigrationFactory { $ErrorActionPreference } | Should -Be 'Stop'
    }

    It 'a NON-terminating error from a callee terminates module execution' {
        # Simulates the real Az-cmdlet shape: a callee that WRITES an error
        # (non-terminating) instead of throwing. Under the module's pinned
        # Stop preference this must terminate, never fall through to the
        # code after the call (the success bookkeeping in the real bug).
        InModuleScope VmMigrationFactory {
            function Test-VmfEapProbe {
                [CmdletBinding()] param()
                Write-Error 'simulated 409: still referenced'
                'reached-after-error'
            }
            { Test-VmfEapProbe } | Should -Throw '*still referenced*'
        }
    }
}

Describe 'Set-VmfVmCapacityReservationGroup (REH-1: disassociation must actually take effect)' {
    # Hand-building CapacityReservationProfile($null) is dropped by the ARM
    # serializer: Update-AzVM returned OK and the VM stayed associated. The
    # function must use Update-AzVM -CapacityReservationGroupId (both
    # directions) and VERIFY the resulting association state.
    BeforeEach {
        $script:vmAssoc = '/s/rg/p/crg/g1'   # simulated current association
        Mock -ModuleName VmMigrationFactory Get-AzVM {
            [pscustomobject]@{
                Id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
                CapacityReservation = if ($script:vmAssoc) {
                    [pscustomobject]@{ CapacityReservationGroup = [pscustomobject]@{ Id = $script:vmAssoc } }
                } else { $null }
            }
        }
        Mock -ModuleName VmMigrationFactory Clear-VmfDiskPerfProperties { $Vm }
    }

    It 'disassociates via a raw PATCH carrying an explicit JSON null, and verifies' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            $script:vmAssoc = $null   # honest fake: applies the change
            [pscustomobject]@{ StatusCode = 200; Content = '' }
        }
        Mock -ModuleName VmMigrationFactory Update-AzVM { throw 'must not be used for disassociation' }
        InModuleScope VmMigrationFactory {
            Set-VmfVmCapacityReservationGroup -ResourceGroupName 'rg' -Name 'vm1' -GroupId $null
        }
        Should -Invoke -ModuleName VmMigrationFactory Invoke-AzRestMethod -Times 1 -Exactly `
            -ParameterFilter { $Method -eq 'PATCH' -and $Payload -match '"capacityReservationGroup":\{"id":null\}' }
    }

    It 'throws when the association state does not change (silent-serializer guard)' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = '' }   # 200 but nothing applied - the REH-1 lie
        }
        InModuleScope VmMigrationFactory {
            { Set-VmfVmCapacityReservationGroup -ResourceGroupName 'rg' -Name 'vm1' -GroupId $null } |
                Should -Throw '*did not take effect*'
        }
    }

    It 'associates to a group id and verifies' {
        $script:vmAssoc = $null
        Mock -ModuleName VmMigrationFactory Update-AzVM {
            $script:vmAssoc = $CapacityReservationGroupId
            [pscustomobject]@{ StatusCode = 'OK' }
        }
        InModuleScope VmMigrationFactory {
            Set-VmfVmCapacityReservationGroup -ResourceGroupName 'rg' -Name 'vm1' -GroupId '/s/rg/p/crg/g2'
        }
        Should -Invoke -ModuleName VmMigrationFactory Update-AzVM -Times 1 -Exactly `
            -ParameterFilter { $CapacityReservationGroupId -eq '/s/rg/p/crg/g2' }
    }
}

Describe 'Remove-VmfCapacityReservation (REH-1: disassociation is eventually consistent)' {
    # The wave rehearsal hit a 409 "still referenced by VM" deleting a
    # reservation immediately after the disassociation PATCHes returned:
    # the reference clears asynchronously. Delete must wait until the
    # reservation reports zero VM references.
    It 'polls until the reservation is unreferenced, THEN deletes' {
        $script:polls = 0
        Mock -ModuleName VmMigrationFactory Get-AzCapacityReservation {
            if ($Name) {
                $script:polls++
                [pscustomobject]@{
                    Name = $Name
                    VirtualMachinesAssociated = if ($script:polls -lt 3) { @(@{ Id = '/vm1' }) } else { @() }
                }
            }
            else { @() }   # group-level listing after delete: empty -> group removed
        }
        Mock -ModuleName VmMigrationFactory Remove-AzCapacityReservation { }
        Mock -ModuleName VmMigrationFactory Remove-AzCapacityReservationGroup { }

        InModuleScope VmMigrationFactory {
            Remove-VmfCapacityReservation -ResourceGroupName 'rg' -GroupName 'g' -ReservationName 'r' -SubscriptionId '00000000-0000-0000-0000-000000000000' -PollSeconds 0
        }
        $script:polls | Should -BeGreaterOrEqual 3
        Should -Invoke -ModuleName VmMigrationFactory Remove-AzCapacityReservation -Times 1 -Exactly
    }

    It 'throws when references never clear within the timeout' {
        Mock -ModuleName VmMigrationFactory Get-AzCapacityReservation {
            [pscustomobject]@{ Name = 'r'; VirtualMachinesAssociated = @(@{ Id = '/vm1' }) }
        }
        Mock -ModuleName VmMigrationFactory Remove-AzCapacityReservation { }
        InModuleScope VmMigrationFactory {
            { Remove-VmfCapacityReservation -ResourceGroupName 'rg' -GroupName 'g' -ReservationName 'r' -SubscriptionId '00000000-0000-0000-0000-000000000000' `
                -PollSeconds 0 -UnreferencedTimeoutSeconds 0 } | Should -Throw '*still referenced*'
        }
        Should -Invoke -ModuleName VmMigrationFactory Remove-AzCapacityReservation -Times 0 -Exactly
    }
}

Describe 'Invoke-VmfAzOperation' {

    It 'returns the operation result on first success' {
        InModuleScope VmMigrationFactory {
            Invoke-VmfAzOperation -Name 'test' -Operation { 42 } | Should -Be 42
        }
    }

    It 'retries transient (429) failures then succeeds' {
        InModuleScope VmMigrationFactory {
            $script:calls = 0
            $result = Invoke-VmfAzOperation -Name 'test' -BaseDelayMs 1 -Operation {
                $script:calls++
                if ($script:calls -lt 3) { throw 'Response status code 429 (TooManyRequests)' }
                'done'
            }
            $result | Should -Be 'done'
            $script:calls | Should -Be 3
        }
    }

    It 'does NOT retry non-transient errors' {
        InModuleScope VmMigrationFactory {
            $script:calls = 0
            {
                Invoke-VmfAzOperation -Name 'test' -BaseDelayMs 1 -Operation {
                    $script:calls++
                    throw 'AuthorizationFailed: does not have permission'
                }
            } | Should -Throw '*AuthorizationFailed*'
            $script:calls | Should -Be 1
        }
    }

    It 'gives up after MaxAttempts on persistent throttling' {
        InModuleScope VmMigrationFactory {
            $script:calls = 0
            {
                Invoke-VmfAzOperation -Name 'test' -MaxAttempts 3 -BaseDelayMs 1 -Operation {
                    $script:calls++
                    throw 'throttled: Response status code 429'
                }
            } | Should -Throw '*429*'
            $script:calls | Should -Be 3
        }
    }

    # S3-7 live finding: a state that runs several 60s guest commands renews
    # its lease only between STATES, so the watchdog falsely reaped a healthy
    # worker mid-GUEST_PREP. Every ARM call flows through this wrapper, so the
    # wrapper is where in-step lease renewal lives.
    It 'invokes the module heartbeat hook before each operation (S3-7)' {
        InModuleScope VmMigrationFactory {
            $script:beats = 0
            $script:VmfOpHeartbeat = { $script:beats++ }
            try {
                Invoke-VmfAzOperation -Name 'test' -Operation { 'x' } | Out-Null
                Invoke-VmfAzOperation -Name 'test' -Operation { 'y' } | Out-Null
                $script:beats | Should -Be 2
            }
            finally { $script:VmfOpHeartbeat = $null }
        }
    }

    It 'a lost lease thrown by the heartbeat hook aborts immediately - never retried as transient (S3-7)' {
        InModuleScope VmMigrationFactory {
            $script:calls = 0
            $script:VmfOpHeartbeat = { throw "Lease for 'vm' is held by 'worker-2', not 'worker-1' - abandon this VM." }
            try {
                {
                    Invoke-VmfAzOperation -Name 'test' -BaseDelayMs 1 -Operation { $script:calls++; 'x' }
                } | Should -Throw '*abandon this VM*'
                $script:calls | Should -Be 0
            }
            finally { $script:VmfOpHeartbeat = $null }
        }
    }

    It 'logs ok/retry/fail events when RunPath is provided' {
        InModuleScope VmMigrationFactory {
            $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-aztest-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path $rp -Force | Out-Null
            try {
                $script:calls = 0
                Invoke-VmfAzOperation -Name 'op' -RunPath $rp -VmId 'vm1' -BaseDelayMs 1 -Operation {
                    $script:calls++
                    if ($script:calls -lt 2) { throw '429 throttled' }
                    'ok'
                } | Out-Null
                $events = Read-VmfEvents -RunPath $rp
                @($events | Where-Object outcome -eq 'retry').Count | Should -Be 1
                @($events | Where-Object outcome -eq 'ok').Count | Should -Be 1
            }
            finally { Remove-Item $rp -Recurse -Force }
        }
    }

    # STEP-LOG-1 (review): the "ok" line was inside the operation's try. A line
    # that could not be written landed in the catch, which read a store error
    # that looks transient (503, a timeout) as Azure's - and ran the operation,
    # which had already succeeded, AGAIN.
    It 'STEP-LOG-1: the "ok" line cannot be written - the operation that succeeded is not run again, and its result comes back' {
        Mock -ModuleName VmMigrationFactory Write-Warning { }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Outcome -eq 'ok' } { throw 'The remote server returned an error: (503) Server Unavailable.' }
        InModuleScope VmMigrationFactory {
            $script:calls = 0
            $result = Invoke-VmfAzOperation -Name 'resize' -RunPath (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-no-store') -VmId 'vm1' -BaseDelayMs 1 -Operation {
                $script:calls++
                'resized'
            }
            $result | Should -Be 'resized'
            $script:calls | Should -Be 1 -Because 'the resize was done; a line that was not written is not a reason to resize again'
        }
        Should -Invoke -ModuleName VmMigrationFactory Write-Warning -ParameterFilter { $Message -match 'azureops:resize ok' } -Times 1 -Exactly
    }

    It 'STEP-LOG-1: the "fail" line cannot be written - the Azure error is the one that comes back' {
        Mock -ModuleName VmMigrationFactory Write-Warning { }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        InModuleScope VmMigrationFactory {
            { Invoke-VmfAzOperation -Name 'resize' -RunPath (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-no-store') -VmId 'vm1' -BaseDelayMs 1 -Operation {
                    throw 'AuthorizationFailed: does not have permission'
                } } | Should -Throw '*AuthorizationFailed*'
        }
    }

    It 'STEP-LOG-1 (second review): the "retry" line cannot be written - the retry still runs and the result comes back' {
        Mock -ModuleName VmMigrationFactory Write-Warning { }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Outcome -eq 'retry' } { throw 'The store did not answer.' }
        InModuleScope VmMigrationFactory {
            $script:calls = 0
            $result = Invoke-VmfAzOperation -Name 'resize' -RunPath (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-no-store') -VmId 'vm1' -BaseDelayMs 1 -Operation {
                $script:calls++
                if ($script:calls -lt 2) { throw 'Response status code 429 (TooManyRequests)' }
                'resized'
            }
            $result | Should -Be 'resized'
            $script:calls | Should -Be 2
        }
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Outcome -eq 'retry' } -Times 1 -Exactly
    }

    It 'STEP-LOG-1 (second review): a lost lease at the "ok" line is never read as a transient Azure error - the operation that succeeded is not run again' {
        # The machine's id holds "503"; inside the operation's try the
        # catch read that as transient and ran the operation again.
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Outcome -eq 'ok' } { throw "Lease for 'vm-503' is held by 'worker-2' - abandon this VM." }
        InModuleScope VmMigrationFactory {
            $script:calls = 0
            { Invoke-VmfAzOperation -Name 'resize' -RunPath (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-no-store') -VmId 'vm-503' -BaseDelayMs 1 -Operation {
                    $script:calls++
                    'resized'
                } } | Should -Throw '*abandon this VM*'
            $script:calls | Should -Be 1 -Because 'the resize was done; a lost lease stops the worker, it never resizes again'
        }
    }
}

Describe 'Get-VmfVmCapture' {
    It 'captures a full VM config as a JSON-safe structure' {
        InModuleScope VmMigrationFactory {
            $vm = [pscustomobject]@{
                Id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
                Name = 'vm1'; Location = 'centralus'
                HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_E8bds_v5' }
                StorageProfile = [pscustomobject]@{
                    DiskControllerType = 'SCSI'
                    OsDisk = [pscustomobject]@{
                        OsType = 'Windows'; Name = 'vm1-os'
                        ManagedDisk = [pscustomobject]@{ Id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/vm1-os' }
                        DeleteOption = 'Delete'
                    }
                    DataDisks = @(
                        [pscustomobject]@{ Name = 'dd0'; Lun = 0; Caching = 'ReadOnly'; DiskSizeGB = 512
                            ManagedDisk = [pscustomobject]@{ Id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/dd0'; StorageAccountType = 'PremiumV2_LRS' }
                            DeleteOption = 'Detach' }
                    )
                    ImageReference = [pscustomobject]@{ Publisher = 'MicrosoftWindowsServer'; Offer = 'WindowsServer'; Sku = '2022-datacenter-g2' }
                }
                NetworkProfile = [pscustomobject]@{
                    NetworkInterfaces = @([pscustomobject]@{ Id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic1'; Primary = $true })
                }
                Zones = @('2'); Tags = @{ env = 'prod' }
                LicenseType = 'Windows_Server'
                AvailabilitySetReference = $null; ProximityPlacementGroup = $null
                Priority = 'Regular'; Identity = $null; AdditionalCapabilities = $null
                DiagnosticsProfile = [pscustomobject]@{
                    BootDiagnostics = [pscustomobject]@{ Enabled = $true; StorageUri = $null }
                }
            }
            $cap = Get-VmfVmCapture -Vm $vm
            $cap.size | Should -Be 'Standard_E8bds_v5'
            $cap.controller | Should -Be 'SCSI'
            $cap.osDisk.name | Should -Be 'vm1-os'
            @($cap.dataDisks).Count | Should -Be 1
            @($cap.dataDisks)[0].lun | Should -Be 0
            # SAFETY-ALL-1: a put-back makes the disk again, and needs its type.
            @($cap.dataDisks)[0].skuName | Should -Be 'PremiumV2_LRS'
            @($cap.nics)[0].primary | Should -BeTrue
            $cap.zones | Should -Be @('2')
            $cap.tags.env | Should -Be 'prod'
            $cap.bootDiagnostics.enabled | Should -BeTrue
            $cap.imageReference.sku | Should -Be '2022-datacenter-g2'
            # survives a JSON round trip (state-doc requirement)
            $rt = $cap | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            $rt.osDisk.managedDiskId | Should -Be $cap.osDisk.managedDiskId
        }
    }
}

Describe 'Stop-VmfVmDeallocated' {
    It 'returns immediately when already deallocated (no Stop-AzVM call)' {
        Mock -ModuleName VmMigrationFactory Get-AzVM {
            [pscustomobject]@{ Statuses = @([pscustomobject]@{ Code = 'PowerState/deallocated' }) }
        }
        Mock -ModuleName VmMigrationFactory Stop-AzVM { throw 'should not be called' }
        InModuleScope VmMigrationFactory {
            { Stop-VmfVmDeallocated -ResourceGroupName 'rg' -Name 'vm1' -TimeoutSeconds 5 -PollIntervalSeconds 1 } |
                Should -Not -Throw
        }
        Should -Invoke -ModuleName VmMigrationFactory Stop-AzVM -Times 0
    }

    It 'stops then polls until deallocated' {
        $script:pollCount = 0
        Mock -ModuleName VmMigrationFactory Get-AzVM {
            $script:pollCount++
            $state = if ($script:pollCount -ge 3) { 'PowerState/deallocated' } else { 'PowerState/running' }
            [pscustomobject]@{ Statuses = @([pscustomobject]@{ Code = $state }) }
        }
        Mock -ModuleName VmMigrationFactory Stop-AzVM { $null }
        InModuleScope VmMigrationFactory {
            { Stop-VmfVmDeallocated -ResourceGroupName 'rg' -Name 'vm1' -TimeoutSeconds 30 -PollIntervalSeconds 0 } |
                Should -Not -Throw
        }
        Should -Invoke -ModuleName VmMigrationFactory Stop-AzVM -Times 1 -Exactly
    }

    It 'throws on timeout' {
        Mock -ModuleName VmMigrationFactory Get-AzVM {
            [pscustomobject]@{ Statuses = @([pscustomobject]@{ Code = 'PowerState/running' }) }
        }
        Mock -ModuleName VmMigrationFactory Stop-AzVM { $null }
        InModuleScope VmMigrationFactory {
            { Stop-VmfVmDeallocated -ResourceGroupName 'rg' -Name 'vm1' -TimeoutSeconds 1 -PollIntervalSeconds 0 } |
                Should -Throw '*did not reach*'
        }
    }
}

Describe 'Set-VmfOsDiskControllerTypes' {
    It 'skips the update when the capability already matches' {
        Mock -ModuleName VmMigrationFactory Get-AzDisk {
            [pscustomobject]@{ SupportedCapabilities = [pscustomobject]@{ DiskControllerTypes = 'SCSI, NVMe' } }
        }
        Mock -ModuleName VmMigrationFactory Update-AzDisk { throw 'should not be called' }
        InModuleScope VmMigrationFactory {
            { Set-VmfOsDiskControllerTypes -DiskResourceGroup 'rg' -DiskName 'd1' -ControllerTypes 'SCSI, NVMe' } |
                Should -Not -Throw
        }
        Should -Invoke -ModuleName VmMigrationFactory Update-AzDisk -Times 0
    }

    It 'updates and verifies provisioning state' {
        Mock -ModuleName VmMigrationFactory Get-AzDisk {
            [pscustomobject]@{ SupportedCapabilities = [pscustomobject]@{ DiskControllerTypes = $null } }
        }
        Mock -ModuleName VmMigrationFactory Update-AzDisk {
            [pscustomobject]@{ ProvisioningState = 'Succeeded' }
        }
        InModuleScope VmMigrationFactory {
            { Set-VmfOsDiskControllerTypes -DiskResourceGroup 'rg' -DiskName 'd1' -ControllerTypes 'SCSI, NVMe' } |
                Should -Not -Throw
        }
        Should -Invoke -ModuleName VmMigrationFactory Update-AzDisk -Times 1 -Exactly
    }

    It 'throws when the update does not succeed' {
        Mock -ModuleName VmMigrationFactory Get-AzDisk {
            [pscustomobject]@{ SupportedCapabilities = [pscustomobject]@{ DiskControllerTypes = $null } }
        }
        Mock -ModuleName VmMigrationFactory Update-AzDisk {
            [pscustomobject]@{ ProvisioningState = 'Failed' }
        }
        InModuleScope VmMigrationFactory {
            { Set-VmfOsDiskControllerTypes -DiskResourceGroup 'rg' -DiskName 'd1' -ControllerTypes 'SCSI, NVMe' } |
                Should -Throw '*provisioning state*'
        }
    }
}

Describe 'Get-VmfSkuCatalog' {
    It 'fetches once per location and caches' {
        Mock -ModuleName VmMigrationFactory Get-AzComputeResourceSku {
            @([pscustomobject]@{ Name = 'Standard_D2s_v6'; ResourceType = 'virtualMachines' })
        }
        InModuleScope VmMigrationFactory {
            $script:VmfSkuCache = $null
            (Get-VmfSkuCatalog -Location 'centralus').Name | Should -Contain 'Standard_D2s_v6'
            Get-VmfSkuCatalog -Location 'centralus' | Out-Null
            Get-VmfSkuCatalog -Location 'CentralUS' | Out-Null   # case-insensitive cache hit
        }
        Should -Invoke -ModuleName VmMigrationFactory Get-AzComputeResourceSku -Times 1 -Exactly
    }

    It '-Refresh bypasses the cache' {
        Mock -ModuleName VmMigrationFactory Get-AzComputeResourceSku {
            @([pscustomobject]@{ Name = 'Standard_D2s_v6'; ResourceType = 'virtualMachines' })
        }
        InModuleScope VmMigrationFactory {
            $script:VmfSkuCache = $null
            Get-VmfSkuCatalog -Location 'eastus2' | Out-Null
            Get-VmfSkuCatalog -Location 'eastus2' -Refresh | Out-Null
        }
        Should -Invoke -ModuleName VmMigrationFactory Get-AzComputeResourceSku -Times 2 -Exactly
    }
}

Describe 'ConvertTo-VmfTagTable (P1-6 regression)' {
    It 'converts a JSON-round-tripped PSCustomObject to Hashtable[string,string]' {
        InModuleScope VmMigrationFactory {
            # exactly what a capture looks like after the state-store round trip
            $roundTripped = (@{ tags = @{ project = 'vmf'; purpose = 'lab' } } | ConvertTo-Json | ConvertFrom-Json).tags
            $roundTripped | Should -BeOfType [pscustomobject]
            $table = ConvertTo-VmfTagTable -Tags $roundTripped
            # MUST be a real generic Dictionary - the VM config Tags property is
            # IDictionary[string,string] and PowerShell won't convert Hashtable to it
            $table.GetType().FullName | Should -Match 'Dictionary`2'
            $table['project'] | Should -Be 'vmf'
            $table['purpose'] | Should -Be 'lab'
            $table.Count | Should -Be 2
            # assignable to the generic interface (what the VM config setter needs)
            { [System.Collections.Generic.IDictionary[string, string]]$i = $table; $i.Count } | Should -Not -Throw
        }
    }
    It 'converts hashtables and handles null' {
        InModuleScope VmMigrationFactory {
            (ConvertTo-VmfTagTable -Tags @{ a = 'b' })['a'] | Should -Be 'b'
            (ConvertTo-VmfTagTable -Tags $null).Count | Should -Be 0
        }
    }
}
