#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# UAMI-ASSIGN-1: every write of a machine with a USER-ASSIGNED managed identity
# assigns that identity again, and Azure checks the assign on the IDENTITY.
#
# MEASURED 2026-11-01 in the lab, through the app, with the product's own VMF
# Migration role alone: a Windows machine with a user-assigned identity failed
# on BOTH paths - Path B (D2ds_v4 to D2ds_v6) and Path A (D2ds_v4 to D2ds_v5).
# The first write of the machine was refused (redacted):
#
#   has permission to perform action 'Microsoft.Compute/virtualMachines/write'
#   ... however, it does not have permission to perform action(s)
#   'Microsoft.ManagedIdentity/userAssignedIdentities/assign/action' on the
#   linked scope(s) '<the identity>' ... LinkedAuthorizationFailed
#
# The automatic rollback made the same write and was refused the same way, so
# the machine was left stopped, with "the rollback also failed". Same class as
# NIC-JOIN-1 and ROLE-SNAP-1: a write is checked on every resource it links to.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # SQLVM-REREAD-1: Checking reads the SQL virtual machine resource before a rebuild; none here.
    # DCR-READ-1: Checking reads the data collection rule associations before a rebuild; none here.
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'uami'

    $script:assign = 'Microsoft.ManagedIdentity/userAssignedIdentities/assign/action'
    $script:zero = '00000000-0000-0000-0000-000000000000'
    $script:vmRg = "/subscriptions/$script:zero/resourceGroups/rg-app"
    $script:vmId = "$script:vmRg/providers/Microsoft.Compute/virtualMachines/vm1"
    # Two identities, as a customer's platform team often keeps them: in a
    # resource group of their own, one of them in another subscription.
    $script:miApp = "/subscriptions/$script:zero/resourceGroups/rg-ids/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-app"
    $script:miOps = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-shared/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-ops'
    $script:map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json

    function Script:NewRp {
        $rp = Join-Path $script:temp "r-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'uami' | Out-Null }
        $rp
    }
    # The capture as Get-VmfVmCapture writes it.
    function Script:Cap([string]$Type, [string[]]$Ids) {
        [ordered]@{ name = 'vm1'; identityType = $Type
            identity = $(if ($Type) { [ordered]@{ type = $Type; userAssignedIds = @($Ids); principalId = '' } } else { $null }) }
    }
    function Script:Gate($Capture) {
        $rp = Script:NewRp
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; cap = $Capture } {
            param($rp, $id, $cap)
            Test-VmfIdentityAssignPermissions -Context @{ RunPath = $rp; VmId = $id } -Capture $cap
        }
    }
}

AfterAll { Remove-VmfTestTemp }

Describe 'UAMI-ASSIGN-1: the role carries the assign' {

    It 'every call that writes the machine lists the assign Azure demanded, with the reason' {
        # REBUILD-REMOVE-ROLE-1: New-AzVM left the map with the rebuild.
        foreach ($c in 'Update-AzVM') {
            $op = @($script:map.operations | Where-Object cmdlet -EQ $c)
            $op.Count | Should -Be 1 -Because "exactly one mapped $c"
            $op[0].role | Should -Be 'execute'
            @($op[0].actions) | Should -Contain $script:assign
            $op[0].why | Should -Match 'UAMI-ASSIGN-1'
            $op[0].why | Should -Match 'LinkedAuthorizationFailed'
            $op[0].why | Should -Match 'Managed Identity Operator' -Because 'where the action was read from, so it can be checked again'
        }
    }

    It 'the assessment role does not gain it - it changes nothing' {
        $assess = @($script:map.operations | Where-Object role -EQ 'assess' | ForEach-Object { $_.actions })
        $assess | Should -Not -Contain $script:assign
        @($assess | Where-Object { $_ -like 'Microsoft.ManagedIdentity/*' }) | Should -BeNullOrEmpty
    }

    It 'the check asks for exactly the action the role grants - it cannot demand what the role lacks' {
        $asked = InModuleScope VmMigrationFactory { $script:VmfIdentityAssignAction }
        $asked | Should -Be $script:assign
        $granted = @($script:map.operations | Where-Object role -EQ 'execute' | ForEach-Object { $_.actions })
        $granted | Should -Contain $asked
    }
}

Describe 'UAMI-ASSIGN-1: a wildcard in the middle of an action' {

    It 'REVIEW: the shared matcher never reads "/*/" as no segment - X/*/write does not grant X/write' {
        # The first version of this item made every "/*/" match no segment,
        # so virtualMachines/*/write (extension and run command writes) passed
        # the machine write: a false pass into the stopped window.
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:assign } {
            Test-VmfActionGranted -Action 'Microsoft.Compute/virtualMachines/write' -Actions @('Microsoft.Compute/virtualMachines/*/write') | Should -BeFalse
            Test-VmfActionGranted -Action 'Microsoft.Compute/virtualMachines/read' -Actions @('Microsoft.Compute/virtualMachines/*/read') | Should -BeFalse
            Test-VmfActionGranted -Action 'Microsoft.Authorization/locks/write' -Actions @('Microsoft.Authorization/locks/*/write') | Should -BeFalse
            # Even the identity's own action: the shared matcher does not
            # accept the documented form; only Test-VmfIdentityAssignHeld does.
            Test-VmfActionGranted -Action $a -Actions @('Microsoft.ManagedIdentity/userAssignedIdentities/*/assign/action') | Should -BeFalse
        }
    }

    It 'and still matches one segment or more' {
        InModuleScope VmMigrationFactory {
            Test-VmfActionGranted -Action 'Microsoft.Compute/virtualMachines/extensions/read' -Actions @('Microsoft.Compute/*/read') | Should -BeTrue
            Test-VmfActionGranted -Action 'Microsoft.Compute/virtualMachines/extensions/write' -Actions @('Microsoft.Compute/virtualMachines/*/write') | Should -BeTrue
        }
    }

    It 'Managed Identity Operator grants the assign, for this action only' {
        # Microsoft's FAQ names Microsoft.ManagedIdentity/userAssignedIdentities/*/assign/action,
        # carried by the built-in Managed Identity Operator, as what assigning
        # needs - and Azure's refusal names the operation without a segment.
        $held = { param($acts, $nots) InModuleScope VmMigrationFactory -Parameters @{ a = $acts; n = $nots } {
                Test-VmfIdentityAssignHeld -Permissions @([pscustomobject]@{ actions = @($a); notActions = @($n) }) } }
        & $held @('Microsoft.ManagedIdentity/userAssignedIdentities/*/read', 'Microsoft.ManagedIdentity/userAssignedIdentities/*/assign/action') @() | Should -BeTrue
        & $held @($script:assign) @() | Should -BeTrue
        & $held @('*') @() | Should -BeTrue
        & $held @('Microsoft.ManagedIdentity/*') @() | Should -BeTrue
        & $held @('Microsoft.ManagedIdentity/userAssignedIdentities/*/read') @() | Should -BeFalse
        & $held @('Microsoft.Compute/*') @() | Should -BeFalse
        & $held @() @() | Should -BeFalse
        # A notAction in either spelling takes it away.
        & $held @('Microsoft.ManagedIdentity/userAssignedIdentities/*/assign/action') @($script:assign) | Should -BeFalse
        & $held @('*') @('Microsoft.ManagedIdentity/userAssignedIdentities/*/assign/action') | Should -BeFalse
    }
}

Describe 'UAMI-ASSIGN-1: the check on each user-assigned identity' {
    BeforeEach {
        $global:uamiAsked = [System.Collections.Generic.List[string]]::new()
        $global:uamiGrants = @{}
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
            $global:uamiAsked.Add($Scope)
            @([pscustomobject]@{ actions = @($global:uamiGrants[$Scope]); notActions = @() })
        }
    }
    AfterEach { Remove-Variable uamiAsked, uamiGrants -Scope Global -ErrorAction SilentlyContinue }

    It 'a machine with no identity, or only a system-assigned one, asks nothing' {
        Script:Gate (Script:Cap $null @()) | Should -BeNullOrEmpty
        Script:Gate (Script:Cap 'SystemAssigned' @()) | Should -BeNullOrEmpty
        $global:uamiAsked.Count | Should -Be 0
    }

    It 'THE DEFECT: an identity this account may not assign stops the machine UNTOUCHED, naming the identity, the action and the role' {
        $global:uamiGrants[$script:miApp] = @('Microsoft.ManagedIdentity/userAssignedIdentities/read')
        $global:uamiGrants[$script:miOps] = @($script:assign)
        $r = Script:Gate (Script:Cap 'UserAssigned' @($script:miApp, $script:miOps, $script:miApp.ToUpperInvariant()))
        @($global:uamiAsked) | Should -Be @($script:miApp, $script:miOps) -Because 'each identity is asked about once, at its OWN scope, whatever the letter case'
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'permissionMissingIdentity'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match ([regex]::Escape("$($script:assign) on $($script:miApp)"))
        $r.Detail | Should -Not -Match ([regex]::Escape($script:miOps)) -Because 'that identity may be assigned'
        # Since 2026-11-01 (PR #688): the stop matches the network and disk
        # encryption set stops - it names the resource and the action, then
        # ends with exactly this sentence.
        $r.Detail | Should -Match ([regex]::Escape('The run stopped before touching the machine. Grant the VMF Migration role where the managed identity is, then try again.') + '$')
        $r.Detail | Should -Match 'user-assigned managed identity'
        $r.Detail | Should -Match 'stopped before touching the machine'
    }

    It 'a machine with a system-assigned AND a user-assigned identity is asked about the user-assigned one' {
        $r = Script:Gate (Script:Cap 'SystemAssigned, UserAssigned' @($script:miApp))
        @($global:uamiAsked) | Should -Be @($script:miApp)
        $r.Reason | Should -Be 'permissionMissingIdentity'
    }

    It 'Managed Identity Operator on the identity covers it, and so does a wildcard' {
        $global:uamiGrants[$script:miApp] = @('Microsoft.ManagedIdentity/userAssignedIdentities/*/read', 'Microsoft.ManagedIdentity/userAssignedIdentities/*/assign/action')
        $global:uamiGrants[$script:miOps] = @('*')
        Script:Gate (Script:Cap 'UserAssigned' @($script:miApp, $script:miOps)) | Should -BeNullOrEmpty
    }

    It 'UNKNOWN IS NOT ALLOWED: a read Azure does not answer stops the machine untouched, naming the identity' {
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
            $global:uamiAsked.Add($Scope)
            if ($Scope -eq $script:miOps) { throw "Could not read effective permissions at '$Scope' (HTTP 403): AuthorizationFailed" }
            @([pscustomobject]@{ actions = @('*'); notActions = @() })
        }
        $r = Script:Gate (Script:Cap 'UserAssigned' @($script:miApp, $script:miOps))
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'identityAssignNotKnown'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match ([regex]::Escape($script:miOps))
        $r.Detail | Should -Match 'AuthorizationFailed'
        $r.Detail | Should -Not -Match ([regex]::Escape($script:miApp)) -Because 'that one was read, and may be assigned'
        $r.Detail | Should -Match 'Nothing on the machine changed\.$'
    }

    It 'a read that fails AND an identity that is missing the grant: the missing grant is the stop, and the read is named too' {
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
            if ($Scope -eq $script:miOps) { throw 'HTTP 404: ResourceNotFound' }
            @([pscustomobject]@{ actions = @('Microsoft.Compute/*'); notActions = @() })
        }
        $r = Script:Gate (Script:Cap 'UserAssigned' @($script:miApp, $script:miOps))
        $r.Reason | Should -Be 'permissionMissingIdentity'
        $r.Detail | Should -Match ([regex]::Escape("$($script:assign) on $($script:miApp)"))
        $r.Detail | Should -Match ([regex]::Escape($script:miOps))
        $r.Detail | Should -Match 'ResourceNotFound'
    }

    It 'Azure reports a user-assigned identity and the capture holds no id: that is unknown, never "nothing to ask"' {
        $r = Script:Gate (Script:Cap 'UserAssigned' @())
        $r.Reason | Should -Be 'identityAssignNotKnown'
        $r.MachineState | Should -Be 'untouched'
        $global:uamiAsked.Count | Should -Be 0
    }

    It 'a worker that lost its lease stops at once, never parked as "not known"' {
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { throw 'Lease lost - abandon this VM' }
        { Script:Gate (Script:Cap 'UserAssigned' @($script:miApp)) } | Should -Throw '*abandon this VM*'
    }
}

Describe 'UAMI-ASSIGN-1: Checking asks before anything is touched' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        function Global:UamiPrecheck([string]$Path, [hashtable]$Grants) {
            # Every Azure function that changes something refuses: PRECHECK
            # must change nothing on any outcome.
            $writes = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops') -Filter '*.ps1' |
                ForEach-Object { Select-String -Path $_.FullName -Pattern '^function\s+([\w-]+)' | ForEach-Object { $_.Matches[0].Groups[1].Value } } |
                Where-Object { $_ -match '^(Stop|Start|Set|New|Remove|Lock|Unlock|Request|Update)-' -or $_ -eq 'Invoke-VmfRunCommand' })
            foreach ($n in $writes) { Mock -ModuleName VmMigrationFactory -CommandName $n -MockWith { throw 'nothing in Azure may change' } }
            $global:uamiScopes = [System.Collections.Generic.List[string]]::new()
            $global:uamiGrantsP = $Grants
            Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
            Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
            Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
                $global:uamiScopes.Add($Scope)
                $g = if ($global:uamiGrantsP.ContainsKey($Scope)) { $global:uamiGrantsP[$Scope] } else { @('*') }
                @([pscustomobject]@{ actions = @($g); notActions = @() })
            }
            Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
            Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { @() }
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
            # Accelerated networking is on: Intel v5 requires it (GEN-V5-1).
            Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
            Mock -ModuleName VmMigrationFactory Get-VmfNetworkInterfaceById { [pscustomobject]@{ Id = 'nic0' } }
            Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts {
                [pscustomobject]@{ id = $DiskId; skuName = 'Premium_LRS'; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null; zones = @(); maxShares = 1; completionPercent = 100 }
            }
            $live = [pscustomobject]@{
                Id = $script:vmId; Name = 'vm1'; ResourceGroupName = 'rg-app'; Location = 'centralus'
                HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2ds_v4' }
                StorageProfile = [pscustomobject]@{ DiskControllerType = 'SCSI'
                    OsDisk = [pscustomobject]@{ OsType = 'Windows'; Name = 'vm1-osdisk'; DeleteOption = 'Detach'; ManagedDisk = [pscustomobject]@{ Id = "$($script:vmRg)/providers/Microsoft.Compute/disks/vm1-osdisk"; StorageAccountType = 'Premium_LRS' } }
                    DataDisks = @(); ImageReference = $null }
                NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = "$($script:vmRg)/providers/Microsoft.Network/networkInterfaces/nic0"; Primary = $true }) }
                Zones = @(); Tags = @{}; LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
                Priority = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null; SecurityProfile = $null
                Identity = [pscustomobject]@{ Type = 'UserAssigned'; PrincipalId = $null
                    UserAssignedIdentities = @{ $script:miApp = [pscustomobject]@{ PrincipalId = $script:zero; ClientId = $script:zero } } }
            }
            $global:uamiLive = $live
            Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { $global:uamiLive }
            $rp = Script:NewRp
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; path = $Path } {
                param($rp, $id, $path)
                $target = if ($path -eq 'B') { [pscustomobject]@{ size = 'Standard_D2ds_v6'; diskArch = 'nvme-temp'; controller = 'NVMe' } }
                          else { [pscustomobject]@{ size = 'Standard_D2ds_v5'; diskArch = 'scsi-temp'; controller = 'SCSI' } }
                $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'; path = $path
                    assessment = [pscustomobject]@{ classification = 'Ready'; gen = 'V2'; os = 'Windows'; sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'
                        platformManaged = $false; location = 'centralus'; dataDiskCount = 0 }
                    target = $target
                    policy = [pscustomobject]@{ onDDataFound = 'proceed'; targetGeneration = $(if ($path -eq 'B') { 'v6' } else { 'v5' }); acceleratedNetworking = 'preserve' } }
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'uami'
                New-VmfStateDoc -RunPath $rp -RunId 'uami' -VmId $ctx.VmId | Out-Null
                Invoke-VmfStepPrecheck -Context $ctx
            }
        }
    }
    AfterAll { Remove-Item function:UamiPrecheck -ErrorAction SilentlyContinue }
    AfterEach { Remove-Variable uamiScopes, uamiGrantsP, uamiLive -Scope Global -ErrorAction SilentlyContinue }

    It 'THE DEFECT, Path A (in-place to v5): the identity it may not assign stops Checking, before the first safety copy stops the machine' {
        $r = UamiPrecheck -Path 'A' -Grants @{ $script:miApp = @('Microsoft.ManagedIdentity/userAssignedIdentities/read') }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'permissionMissingIdentity'
        $r.Detail | Should -Match ([regex]::Escape("$($script:assign) on $($script:miApp)"))
        @($global:uamiScopes) | Should -Contain $script:miApp -Because 'asked at the identity, not only at the machine'
    }

    It 'with the role on the identity, Checking goes on to the first safety copy' {
        $r = UamiPrecheck -Path 'A' -Grants @{ $script:miApp = @($script:assign) }
        $r.Next | Should -Be 'SAFETY_PRISTINE' -Because "PRECHECK passes ($($r.Detail))"
        @($global:uamiScopes) | Should -Contain $script:miApp
    }

    It 'the check runs inside Checking, after the capture is saved' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $pre = [regex]::Match($code, '(?s)function Invoke-VmfStepPrecheck \{.*?\nfunction ').Value
        $pre | Should -Match 'Test-VmfIdentityAssignPermissions -Context \$Context -Capture \$capturedConfig'
        $pre.IndexOf('Save-VmfCapturedFacts -Context $Context -Facts $facts') | Should -BeLessThan $pre.IndexOf('Test-VmfIdentityAssignPermissions')
    }
}

Describe 'UAMI-ASSIGN-1: what the operator reads' {
    # Since 2026-11-01: no new guidance tells anyone to give the product
    # access where the identity is. The Admin card grants Assess and migrate
    # on a whole resource group, subscription or management group, so that
    # advice meant stop, resize and rebuild rights over every machine there.

    It 'the stop for an unread permission has its words, a machine state and a retry kind, and asks no grant' {
        $sr = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
        $e = @($sr.reasons | Where-Object code -EQ 'identityAssignNotKnown')
        $e.Count | Should -Be 1
        $e[0].machine | Should -Be 'untouched'
        $e[0].retry | Should -Be 'afterFix'
        $e[0].meaning | Should -Match 'user-assigned managed identity'
        "$($e[0].meaning) $($e[0].whatToDo)" | Should -Not -Match '(?i)grant|give'
    }

    It 'an unread permission names the identity and says it could not be read - and asks no grant' {
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { throw 'HTTP 403: AuthorizationFailed' }
        $r = Script:Gate (Script:Cap 'UserAssigned' @($script:miApp))
        $r.Detail | Should -Match ([regex]::Escape($script:miApp))
        $r.Detail | Should -Match 'could not read'
        $r.Detail | Should -Not -Match '(?i)grant'
    }

    It 'the stop for a missing permission on the machine names only the machine''s own scope' {
        # STOP-TEXT-SPECIFIC-1: each permission stop has its own words now. The
        # one for the machine still gives no advice about where an identity is.
        $sr = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
        $e = @($sr.reasons | Where-Object code -EQ 'permissionsMissing')[0]
        "$($e.meaning) $($e.whatToDo)" | Should -Not -Match 'user-assigned'
        $e.whatToDo | Should -Be 'Grant the VMF Migration role on this machine, its resource group or its subscription. The access Assess and migrate gives this role.'
    }

    It 'the stop for an identity it may not assign names the identity as the place to grant, never a whole resource group' {
        $sr = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
        $e = @($sr.reasons | Where-Object code -EQ 'permissionMissingIdentity')[0]
        $e.whatToDo | Should -Match 'on each user-assigned managed identity that the stop names'
        $e.whatToDo | Should -Not -Match '(?i)resource group|Admin page'
    }

    It 'the permissions page lists the action, and gives no new advice on where to grant' {
        $page = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'permissions.md') -Raw
        # PERMISSIONS-WHY-1: each action is a row of the role's table.
        $page | Should -Match ([regex]::Escape("| ``$($script:assign)`` |"))
        $page | Should -Not -Match '## Where to grant'
    }

    It 'the Admin page says nothing new about where the identities are' {
        $html = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.html'))
        $html | Should -Not -Match 'managed identit'
        (Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'use' 'admin.md') -Raw) | Should -Not -Match 'managed identit'
    }
}