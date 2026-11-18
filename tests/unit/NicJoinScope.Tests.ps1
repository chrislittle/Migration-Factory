#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# NIC-JOIN-SCOPE-1: Checking asks for Microsoft.Network/networkInterfaces/join/action
# on each network interface of the machine, at the interface's OWN scope.
#
# A resize with Update-AzVM sends the whole definition of the machine, its
# network interfaces included. Microsoft names the action "Attach a network
# interface to a virtual machine", and says an interface can be in another
# resource group than its machine. Microsoft Q&A 596739 shows a PowerShell
# resize refused with LinkedAuthorizationFailed for this action on the
# interface - the class this product MEASURED for the user-assigned identity
# (UAMI-ASSIGN-1), where the rollback, the same Update-AzVM call, was refused
# too and the machine stayed stopped. Before this item, Checking asked for the
# role's actions only at the machine's scope, so with the role granted on the
# machine's resource group and the interface in another, Checking passed.
#
# Not measured: whether Azure checks the join on an interface whose reference
# does not change. TESTMATRIX-1 lists the measurement. The check joined 1.0 on
# 2026-11-07 regardless: the case is rare, but the check is good.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'njs'

    $script:join = 'Microsoft.Network/networkInterfaces/join/action'
    $script:zero = '00000000-0000-0000-0000-000000000000'
    $script:vmRg = "/subscriptions/$script:zero/resourceGroups/rg-app"
    $script:vmId = "$script:vmRg/providers/Microsoft.Compute/virtualMachines/vm1"
    # One interface beside the machine, one in the network team's group.
    $script:nicSame = "$script:vmRg/providers/Microsoft.Network/networkInterfaces/vm1-nic"
    $script:nicOther = "/subscriptions/$script:zero/resourceGroups/rg-net/providers/Microsoft.Network/networkInterfaces/vm1-nic2"
    $script:map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
    $script:table = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw -Encoding utf8 | ConvertFrom-Json

    function Script:NewRp {
        $rp = Join-Path $script:temp "r-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'njs' | Out-Null }
        $rp
    }
    # The interfaces as Get-VmfVmCapture writes them.
    function Script:Nic([string]$Id, [bool]$Primary = $true) {
        [ordered]@{ id = $Id; primary = $Primary; acceleratedNetworking = $true; deleteOption = 'Detach' }
    }
    function Script:Gate($Nics) {
        $rp = Script:NewRp
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; n = $Nics } {
            param($rp, $id, $n)
            Test-VmfNicJoinPermissions -Context @{ RunPath = $rp; VmId = $id } -CapturedNics $n
        }
    }
}

AfterAll { Remove-VmfTestTemp }

Describe 'NIC-JOIN-SCOPE-1: the role carries the join, and the check asks only for it' {

    It 'the resize lists the join, and its why names this check' {
        $op = @($script:map.operations | Where-Object cmdlet -EQ 'Update-AzVM')
        $op.Count | Should -Be 1
        $op[0].role | Should -Be 'execute'
        @($op[0].actions) | Should -Contain $script:join
        $op[0].why | Should -Match 'NIC-JOIN-SCOPE-1'
        $op[0].why | Should -Match 'Test-VmfNicJoinPermissions'
    }

    It 'the check asks for exactly the action the role grants - it cannot demand what the role lacks' {
        $asked = InModuleScope VmMigrationFactory { $script:VmfNicJoinAction }
        $asked | Should -Be $script:join
        @($script:map.operations | Where-Object role -EQ 'execute' | ForEach-Object { $_.actions }) | Should -Contain $asked
    }
}

Describe 'NIC-JOIN-SCOPE-1: the check on each network interface' {
    BeforeEach {
        $global:njsAsked = [System.Collections.Generic.List[string]]::new()
        $global:njsGrants = @{}
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
            $global:njsAsked.Add($Scope)
            @([pscustomobject]@{ actions = @($global:njsGrants[$Scope]); notActions = @() })
        }
    }
    AfterEach { Remove-Variable njsAsked, njsGrants -Scope Global -ErrorAction SilentlyContinue }

    It 'an interface in the machine''s resource group, with the role on that group, passes - asked at the interface' {
        $global:njsGrants[$script:nicSame] = @('Microsoft.Compute/*', 'Microsoft.Network/*')
        Script:Gate @(Script:Nic $script:nicSame) | Should -BeNullOrEmpty
        @($global:njsAsked) | Should -Be @($script:nicSame)
    }

    It 'an interface in the machine''s resource group, with the role on the machine alone, stops - so it is always asked' {
        # A grant on the machine resource does not reach its interface, even
        # beside it: RBAC inheritance runs down from a scope, never across.
        $global:njsGrants[$script:nicSame] = @()
        $r = Script:Gate @(Script:Nic $script:nicSame)
        $r.Reason | Should -Be 'permissionMissingNetworkInterface'
        $r.Detail | Should -Match "'vm1-nic'"
        $r.Detail | Should -Match "'rg-app'"
    }

    It 'THE DEFECT: an interface in another resource group, without the join, stops UNTOUCHED, naming the interface, its group, the action and the grant' {
        $global:njsGrants[$script:nicSame] = @('*')
        $global:njsGrants[$script:nicOther] = @('Microsoft.Network/networkInterfaces/read')
        $r = Script:Gate @((Script:Nic $script:nicSame), (Script:Nic $script:nicOther $false))
        @($global:njsAsked) | Should -Be @($script:nicSame, $script:nicOther) -Because 'each interface is asked at its OWN scope'
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'permissionMissingNetworkInterface'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match "network interface 'vm1-nic2' in the resource group 'rg-net'"
        $r.Detail | Should -Match ([regex]::Escape("$($script:join) on $($script:nicOther)"))
        $r.Detail | Should -Not -Match "'vm1-nic'" -Because 'that interface may be joined'
        $r.Detail | Should -Match 'The run stopped before touching the machine\.'
        # Rule 12: the grant goes through the app, never a command.
        $r.Detail | Should -Match 'VMF Migration role'
        # Since 2026-11-07: say WHAT is needed, never where or how - grant the
        # role on a scope that covers the interface, and customers decide how
        # they do that.
        $advice = 'Grant the VMF Migration role on a scope that covers each network interface that this stop names.'
        $r.Detail | Should -Match ([regex]::Escape($advice))
        $r.Detail | Should -Not -Match '(?i)Admin page|Azure portal|Assess and migrate'
        $sentences = @($r.Detail -split '(?<=\.)\s+' | Where-Object { $_ -match '(?i)\bgrant\b' })
        $sentences | Should -Be @($advice) -Because 'one sentence of advice, and it prescribes no place such as a resource group'
        $r.Detail | Should -Not -Match '(?i)az role|New-AzRoleAssignment|\baz\b'
    }

    It 'an interface in another resource group, with the join there, passes' {
        $global:njsGrants[$script:nicSame] = @($script:join)
        $global:njsGrants[$script:nicOther] = @($script:join)
        Script:Gate @((Script:Nic $script:nicSame), (Script:Nic $script:nicOther $false)) | Should -BeNullOrEmpty
    }

    It 'a notAction for the join takes it away, even under a wildcard' {
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
            @([pscustomobject]@{ actions = @('*'); notActions = @($script:join) })
        }
        (Script:Gate @(Script:Nic $script:nicOther)).Reason | Should -Be 'permissionMissingNetworkInterface'
    }

    It 'two interfaces both missing it are both named, each with its group' {
        $r = Script:Gate @((Script:Nic $script:nicSame), (Script:Nic $script:nicOther $false))
        $r.Detail | Should -Match "network interfaces 'vm1-nic' in the resource group 'rg-app' and 'vm1-nic2' in the resource group 'rg-net'"
    }

    It 'the same interface twice, in another letter case, is asked about once' {
        $global:njsGrants[$script:nicOther] = @('*')
        Script:Gate @((Script:Nic $script:nicOther), (Script:Nic $script:nicOther.ToUpperInvariant() $false)) | Should -BeNullOrEmpty
        @($global:njsAsked).Count | Should -Be 1
    }

    It 'a machine with no network interface in the capture asks nothing' {
        Script:Gate @() | Should -BeNullOrEmpty
        Script:Gate $null | Should -BeNullOrEmpty
        $global:njsAsked.Count | Should -Be 0
    }

    It 'UNKNOWN IS NOT ALLOWED: a read Azure does not answer stops the machine untouched, naming the interface and the answer' {
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
            if ($Scope -eq $script:nicOther) { throw "Could not read effective permissions at '$Scope' (HTTP 403): AuthorizationFailed" }
            @([pscustomobject]@{ actions = @('*'); notActions = @() })
        }
        $r = Script:Gate @((Script:Nic $script:nicSame), (Script:Nic $script:nicOther $false))
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'networkInterfaceJoinNotKnown'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match ([regex]::Escape($script:nicOther))
        $r.Detail | Should -Match 'AuthorizationFailed'
        $r.Detail | Should -Match 'could not read'
        $r.Detail | Should -Not -Match ([regex]::Escape($script:nicSame)) -Because 'that one was read, and may be joined'
        $r.Detail | Should -Not -Match '(?i)grant'
        $r.Detail | Should -Match 'Nothing on the machine changed\.$'
    }

    It 'a read that fails AND an interface missing the join: the missing join is the stop, and the read is named too' {
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
            if ($Scope -eq $script:nicOther) { throw 'HTTP 404: ResourceNotFound' }
            @([pscustomobject]@{ actions = @('Microsoft.Compute/*'); notActions = @() })
        }
        $r = Script:Gate @((Script:Nic $script:nicSame), (Script:Nic $script:nicOther $false))
        $r.Reason | Should -Be 'permissionMissingNetworkInterface'
        $r.Detail | Should -Match ([regex]::Escape("$($script:join) on $($script:nicSame)"))
        $r.Detail | Should -Match ([regex]::Escape($script:nicOther))
        $r.Detail | Should -Match 'ResourceNotFound'
    }

    It 'an interface the capture holds with no id is unknown, never "nothing to ask"' {
        $global:njsGrants[$script:nicSame] = @('*')
        $r = Script:Gate @((Script:Nic $script:nicSame), (Script:Nic '' $false))
        $r.Reason | Should -Be 'networkInterfaceJoinNotKnown'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match 'no id'
    }

    It 'a worker that lost its lease stops at once, never parked as "not known"' {
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { throw 'Lease lost - abandon this VM' }
        { Script:Gate @(Script:Nic $script:nicOther) } | Should -Throw '*abandon this VM*'
    }
}

Describe 'NIC-JOIN-SCOPE-1: Checking asks before anything is touched, for every move' {
    BeforeAll {
        function Global:NjsPrecheck([hashtable]$Grants, [string]$Policy = 'preserve') {
            # Every Azure function that changes something refuses: PRECHECK
            # must change nothing on any outcome.
            $writes = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops') -Filter '*.ps1' |
                ForEach-Object { Select-String -Path $_.FullName -Pattern '^function\s+([\w-]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } } |
                Where-Object { $_ -match '^(Stop|Start|Set|New|Remove|Lock|Unlock|Request|Update)-' -or $_ -eq 'Invoke-VmfRunCommand' })
            foreach ($n in $writes) { Mock -ModuleName VmMigrationFactory -CommandName $n -MockWith { throw 'nothing in Azure may change' } }
            $global:njsScopes = [System.Collections.Generic.List[string]]::new()
            $global:njsGrantsP = $Grants
            Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
            Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
            Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
                $global:njsScopes.Add($Scope)
                $g = if ($global:njsGrantsP.ContainsKey($Scope)) { $global:njsGrantsP[$Scope] } else { @('*') }
                @([pscustomobject]@{ actions = @($g); notActions = @() })
            }
            Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
            Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { @() }
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
            # Accelerated networking is already on (Intel v5 requires it), so
            # this move writes no network interface at all.
            Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
            Mock -ModuleName VmMigrationFactory Get-VmfNetworkInterfaceById { [pscustomobject]@{ Id = 'nic0' } }
            Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts {
                [pscustomobject]@{ id = $DiskId; skuName = 'Premium_LRS'; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null; zones = @(); maxShares = 1; completionPercent = 100 }
            }
            $global:njsLive = [pscustomobject]@{
                Id = $script:vmId; Name = 'vm1'; ResourceGroupName = 'rg-app'; Location = 'centralus'
                HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2ds_v4' }
                StorageProfile = [pscustomobject]@{ DiskControllerType = 'SCSI'
                    OsDisk = [pscustomobject]@{ OsType = 'Linux'; Name = 'vm1-osdisk'; DeleteOption = 'Detach'; ManagedDisk = [pscustomobject]@{ Id = "$($script:vmRg)/providers/Microsoft.Compute/disks/vm1-osdisk"; StorageAccountType = 'Premium_LRS' } }
                    DataDisks = @(); ImageReference = $null }
                NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = $script:nicOther; Primary = $true }) }
                Zones = @(); Tags = @{}; LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
                Priority = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null; SecurityProfile = $null; Identity = $null
            }
            Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { $global:njsLive }
            $rp = Script:NewRp
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; pol = $Policy } {
                param($rp, $id, $pol)
                $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'; path = 'A'
                    assessment = [pscustomobject]@{ classification = 'Ready'; gen = 'V2'; os = 'Linux'; sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'
                        platformManaged = $false; location = 'centralus'; dataDiskCount = 0 }
                    target = [pscustomobject]@{ size = 'Standard_D2ds_v5'; diskArch = 'scsi-temp'; controller = 'SCSI' }
                    policy = [pscustomobject]@{ onDDataFound = 'proceed'; targetGeneration = 'v5'; acceleratedNetworking = $pol } }
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'njs'
                New-VmfStateDoc -RunPath $rp -RunId 'njs' -VmId $ctx.VmId | Out-Null
                Invoke-VmfStepPrecheck -Context $ctx
            }
        }
    }
    AfterAll { Remove-Item function:NjsPrecheck -ErrorAction SilentlyContinue }
    AfterEach { Remove-Variable njsScopes, njsGrantsP, njsLive -Scope Global -ErrorAction SilentlyContinue }

    It 'THE DEFECT: a move that changes no network interface still stops at Checking, before the first safety copy, when the join is missing' {
        $r = NjsPrecheck -Grants @{ $script:nicOther = @('Microsoft.Network/networkInterfaces/read') }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'permissionMissingNetworkInterface'
        $r.Detail | Should -Match ([regex]::Escape("$($script:join) on $($script:nicOther)"))
        @($global:njsScopes) | Should -Contain $script:vmId
        @($global:njsScopes) | Should -Contain $script:nicOther -Because 'asked at the interface, not only at the machine'
    }

    It 'the same with ensureOn, where accelerated networking is already on' {
        (NjsPrecheck -Grants @{ $script:nicOther = @() } -Policy 'ensureOn').Reason | Should -Be 'permissionMissingNetworkInterface'
    }

    It 'with the join on the interface, Checking goes on to the first safety copy' {
        $r = NjsPrecheck -Grants @{ $script:nicOther = @($script:join) }
        $r.Next | Should -Be 'SAFETY_PRISTINE' -Because "PRECHECK passes ($($r.Detail))"
        @($global:njsScopes) | Should -Contain $script:nicOther
    }

    It 'the check runs inside Checking, after the capture is saved, with the captured interfaces' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $pre = [regex]::Match($code, '(?s)function Invoke-VmfStepPrecheck \{.*?\nfunction ').Value
        $pre | Should -Match 'Test-VmfNicJoinPermissions -Context \$Context -CapturedNics \$capturedConfig\.nics'
        $pre.IndexOf('Save-VmfCapturedFacts -Context $Context -Facts $facts') | Should -BeLessThan $pre.IndexOf('Test-VmfNicJoinPermissions')
    }
}

Describe 'NIC-JOIN-SCOPE-1: what the operator reads' {

    It 'the stop for a missing join has its words: untouched, a retry after the fix, the interface, the action, and the role on a scope that covers it - not where' {
        $e = @($script:table.reasons | Where-Object code -EQ 'permissionMissingNetworkInterface')
        $e.Count | Should -Be 1
        $e[0].machine | Should -Be 'untouched'
        $e[0].retry | Should -Be 'afterFix'
        $e[0].title | Should -Match 'network interface'
        $e[0].meaning | Should -Match ([regex]::Escape($script:join))
        $e[0].meaning | Should -Match 'resource group'
        $e[0].whatToDo | Should -Match 'VMF Migration role'
        $e[0].whatToDo | Should -Be 'Grant the VMF Migration role on a scope that covers each network interface that the stop names. The access Assess and migrate gives this role.'
        # Since 2026-11-07: what is needed, not where or how.
        $e[0].whatToDo | Should -Not -Match '(?i)resource group|Admin page|Azure portal'
        "$($e[0].title) $($e[0].meaning) $($e[0].whatToDo)" | Should -Not -Match '(?i)subnet'
    }

    It 'the stop for an unread permission has its words, and asks no grant' {
        $e = @($script:table.reasons | Where-Object code -EQ 'networkInterfaceJoinNotKnown')
        $e.Count | Should -Be 1
        $e[0].machine | Should -Be 'untouched'
        $e[0].retry | Should -Be 'afterFix'
        $e[0].meaning | Should -Match 'network interface'
        "$($e[0].meaning) $($e[0].whatToDo)" | Should -Not -Match '(?i)grant|give'
    }

    It 'the reference page shows both stops (generated from stop-reasons.json)' {
        $page = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'stop-reasons.md') -Raw
        foreach ($code in 'permissionMissingNetworkInterface', 'networkInterfaceJoinNotKnown') {
            $title = @($script:table.reasons | Where-Object code -EQ $code)[0].title
            $page | Should -Match ([regex]::Escape("## $title"))
        }
    }

    It 'the manual says Checking checks the rights on each network interface' {
        $page = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'understand' 'how-a-machine-moves.md') -Raw
        $page | Should -Match 'such as each network interface, its subnet and each user-assigned managed identity'
        $page | Should -Match 'A network interface can be in a different resource group from the machine\.'
    }
}
