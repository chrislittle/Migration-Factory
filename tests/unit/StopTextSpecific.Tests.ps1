#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STOP-TEXT-SPECIFIC-1: every stop names what is missing, on which resource.
#
# Lab Session B, 2026-11-05: the product's identity had no
# Microsoft.Compute/diskEncryptionSets/read on two disk encryption sets. The
# machine stopped untouched, which was right, but the panel said "This account
# cannot finish the migration ... or on a resource that it uses, such as a
# subnet". The text named networking resources such as a subnet that had
# nothing to do with the stop. A stop must say specifically what is missing,
# not a generic list, and the app code had several such texts, so all of them
# were found and changed.
#
# The mechanism is the one the product already has: the reason CODE carries
# the cause (as putBackSizeTooSmall / putBackSizeUnknown and
# identityAssignNotKnown already do), and stop-reasons.json gives each code its
# own words. One code per cause, so no text has to list causes the stop does
# not have. The detail leads with the resource and keeps Azure's action and
# scope.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:table = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw -Encoding utf8 | ConvertFrom-Json
    function Script:Reason([string]$Code) { @($script:table.reasons | Where-Object code -eq $Code)[0] }
    function Script:Words($r) { "$($r.title) $($r.meaning) $($r.whatToDo)" }
    function Script:Classify([string]$Message) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $Message } { Get-VmfErrorStopReason -Message $m }
    }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000'
    $script:desCmk = "$script:sub/resourceGroups/rg-keys/providers/Microsoft.Compute/diskEncryptionSets/contoso-cmk"
    $script:desDouble = "$script:sub/resourceGroups/rg-keys/providers/Microsoft.Compute/diskEncryptionSets/contoso-double"
    $script:subnet = "$script:sub/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/app"
    $script:pip = "$script:sub/resourceGroups/rg-net/providers/Microsoft.Network/publicIPAddresses/app-pip"
    $script:mi = "$script:sub/resourceGroups/rg-id/providers/Microsoft.ManagedIdentity/userAssignedIdentities/app-mi"
    $script:vmId = "$script:sub/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app01"

    # Each permission stop, and the one resource kind it is about. A text of
    # one of them may name no kind of another.
    $script:permissionKinds = [ordered]@{
        permissionsMissing                  = 'this machine'
        permissionMissingNetwork            = 'network interface'
        # NIC-JOIN-SCOPE-1: the join on the network interface itself.
        permissionMissingNetworkInterface   = 'network interface'
        permissionMissingDiskEncryptionSet  = 'disk encryption set'
        permissionMissingIdentity           = 'user-assigned managed identity'
        permissionMissingReservationGroup   = 'capacity reservation group'
    }
    $script:otherKindWords = @('subnet', 'disk encryption set', 'user-assigned managed identity', 'capacity reservation group', 'network interface')
}

Describe 'STOP-TEXT-SPECIFIC-1: one permission stop for each kind of resource' {

    It 'each permission stop has its own reason, untouched, with a retry after the fix' {
        foreach ($code in @($script:permissionKinds.Keys) + 'permissionRefused') {
            $r = Script:Reason $code
            $r | Should -Not -BeNullOrEmpty -Because "$code must have its own guidance"
            $r.retry | Should -Be 'afterFix' -Because $code
        }
    }

    It '<_> names its own kind of resource, and no kind of another stop' -ForEach @(
        'permissionsMissing', 'permissionMissingNetwork', 'permissionMissingDiskEncryptionSet',
        'permissionMissingIdentity', 'permissionMissingReservationGroup', 'permissionMissingNetworkInterface') {
        $r = Script:Reason $_
        $own = $script:permissionKinds[$_]
        "$($r.title) $($r.meaning)" | Should -Match ([regex]::Escape($own)) -Because "the main text of $_ leads with what is missing"
        foreach ($word in $script:otherKindWords | Where-Object { $_ -ne $own }) {
            # The network stop names the interface that links to a subnet; only
            # that stop may say subnet, and it does not need to.
            Script:Words $r | Should -Not -Match "(?i)$([regex]::Escape($word))" -Because "$_ is not about a $word"
        }
    }

    It 'the stop seen in the lab names the disk encryption set and the action' {
        $r = Script:Reason 'permissionMissingDiskEncryptionSet'
        $r.title | Should -Match 'disk encryption set'
        $r.meaning | Should -Match ([regex]::Escape('Microsoft.Compute/diskEncryptionSets/read'))
    }

    It 'each one names the role that fixes it, and where' {
        foreach ($code in $script:permissionKinds.Keys) {
            (Script:Reason $code).whatToDo | Should -Match 'VMF Migration role' -Because $code
        }
        (Script:Reason 'permissionMissingIdentity').whatToDo | Should -Match 'Managed Identity Operator'
        (Script:Reason 'permissionMissingDiskEncryptionSet').whatToDo | Should -Match 'on each disk encryption set that the stop names'
        (Script:Reason 'permissionMissingReservationGroup').whatToDo | Should -Match 'on the capacity reservation group that the stop names'
    }

    It 'a permission Azure refused during the move does not say it was asked before the move' {
        $r = Script:Reason 'permissionRefused'
        Script:Words $r | Should -Match 'AuthorizationFailed'
        Script:Words $r | Should -Not -Match '(?i)before (anything|it changes|the move)'
    }

    It 'no stop says "this account" or "this identity": it is the product''s managed identity' {
        foreach ($r in $script:table.reasons) {
            Script:Words $r | Should -Not -Match '(?i)\bthis (account|identity)\b' -Because "$($r.code) must name the identity"
        }
        (Script:Reason 'permissionsMissing').title | Should -Match ([regex]::Escape("The product's managed identity"))
    }
}

Describe 'STOP-TEXT-SPECIFIC-1: no stop names a cause it does not have' {

    It 'no meaning guesses at a cause' {
        foreach ($r in $script:table.reasons) {
            $r.meaning | Should -Not -Match '(?i)\b(commonly|usually|often)\b' -Because "$($r.code) must say what happened, not what often happens"
        }
        (Script:Reason 'rollbackDisksBeforeMoveNotMade').whatToDo | Should -Not -Match '(?i)usually'
    }

    It 'no capacity: a quota is its own stop' {
        Script:Words (Script:Reason 'capacityUnavailable') | Should -Not -Match '(?i)quota'
        $q = Script:Reason 'quotaExceeded'
        $q | Should -Not -BeNullOrEmpty
        $q.whatToDo | Should -Match 'Request a quota increase'
        "$($q.title) $($q.meaning)" | Should -Match 'size family'
        $q.meaning | Should -Match ([regex]::Escape('A quota does not reserve or guarantee capacity.'))
    }

    It 'a ReadOnly lock is the only lock stop, and it does not say Windows' {
        # REBUILD-REMOVE-LEFTOVERS-1: the CanNotDelete stop (resourceDeleteLocked)
        # was for the removed rebuild; a CanNotDelete lock stops no move.
        $ro = Script:Reason 'resourceLocked'
        (Script:Reason 'resourceDeleteLocked') | Should -BeNullOrEmpty
        "$($ro.title) $($ro.meaning)" | Should -Match 'ReadOnly'
        "$($ro.title) $($ro.meaning)" | Should -Not -Match 'CanNotDelete'
        Script:Words $ro | Should -Not -Match 'Windows'
    }

    It 'a lock that refused a change during the move: the text names no lock type' {
        $code = Script:Classify "ScopeLocked: The scope '/subscriptions/x/resourceGroups/rg' cannot perform delete operation because following scope(s) are locked: '/subscriptions/x/resourceGroups/rg'."
        $r = Script:Reason $code
        $r | Should -Not -BeNullOrEmpty
        $r.title | Should -Not -Match '(?i)ReadOnly|CanNotDelete' -Because 'Azure''s words do not say the lock type'
        Script:Words $r | Should -Not -Match '(?i)ReadOnly|CanNotDelete'
        $r.whatToDo | Should -Match 'resource group'
        $r.retry | Should -Be 'afterFix'
    }

    It 'the two typed lock stops come only from the lock verdict, never from an Azure error' {
        # Code only: the comment above the table names both codes to say why.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $src = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StopReasons.ps1')
        $table = [regex]::Match($src, '(?s)\$patterns = \[ordered\]@\{.*?\r?\n    \}').Value
        $table | Should -Match 'resourceLockRefused'
        $table | Should -Not -BeNullOrEmpty
        $table | Should -Not -Match '\bresourceLocked\b|\bresourceDeleteLocked\b'
    }

    It 'a disabled subscription is not a resource lock' {
        $s = Script:Reason 'subscriptionReadOnly'
        $s | Should -Not -BeNullOrEmpty
        Script:Words $s | Should -Match 'ReadOnlyDisabledSubscription'
        Script:Words $s | Should -Not -Match '(?i)\block\b'
        # Microsoft, Troubleshoot common Cost Management errors: "The
        # subscription is disabled", with the page Reactivate a disabled Azure
        # subscription. Nothing more is claimed.
        $s.meaning | Should -Match 'the subscription is disabled'
        $s.whatToDo | Should -Match 'Reactivate a disabled Azure subscription'
        Script:Words $s | Should -Not -Match '(?i)every change'
    }

    It 'a group it could not read is its own stop' {
        Script:Words (Script:Reason 'reservationGroupNoTargetSize') | Should -Not -Match '(?i)could not read|read access'
        $nr = Script:Reason 'reservationGroupNotRead'
        $nr | Should -Not -BeNullOrEmpty
        $nr.whatToDo | Should -Match 'VMF Assessment role'
    }

    It 'a preview feature it could not read is its own stop' {
        Script:Words (Script:Reason 'previewFeatureNotRegistered') | Should -Not -Match '(?i)could not read'
        $nr = Script:Reason 'previewFeatureNotRead'
        $nr | Should -Not -BeNullOrEmpty
        $nr.meaning | Should -Match 'VMTempDiskResizePreview'
        $nr.whatToDo | Should -Match 'VMF Assessment role'
    }

    It 'the one-interface stop says nothing about the guest; the guest-prep stop says it in its detail' {
        Script:Words (Script:Reason 'targetOneAcceleratedNic') | Should -Not -Match '(?i)Linux Agent|guest preparation'
    }

    It 'the health check and the guest script stops name no cause of their own' {
        (Script:Reason 'validationFailedAfterConversion').meaning | Should -Not -Match '(?i)accelerated networking|extension'
        (Script:Reason 'guestPrepBlocked').meaning | Should -Not -Match '(?i)guest agent|unreachable|registry'
    }
}

Describe 'STOP-TEXT-SPECIFIC-1: an Azure error gets the reason of its cause' {

    It '<Says> is <Code>' -ForEach @(
        @{ Says = 'AuthorizationFailed'; Code = 'permissionRefused'; Message = "AuthorizationFailed: The client does not have authorization to perform action 'Microsoft.Compute/virtualMachines/write'" }
        @{ Says = 'LinkedAuthorizationFailed'; Code = 'permissionRefused'; Message = "LinkedAuthorizationFailed: has permission to perform action 'Microsoft.Network/networkInterfaces/write'; however, it does not have permission to perform action(s) 'Microsoft.Network/virtualNetworks/subnets/join/action'" }
        @{ Says = 'QuotaExceeded'; Code = 'quotaExceeded'; Message = 'QuotaExceeded: Operation could not be completed as it results in exceeding approved standardDDSv6Family quota' }
        @{ Says = 'a quota with no code'; Code = 'quotaExceeded'; Message = 'Operation could not be completed as it results in exceeding approved standardDDSv6Family quota' }
        @{ Says = 'AllocationFailed'; Code = 'capacityUnavailable'; Message = 'AllocationFailed: We do not have sufficient capacity for the requested VM size in this region.' }
        @{ Says = 'ZonalAllocationFailed'; Code = 'capacityUnavailable'; Message = 'ZonalAllocationFailed: Allocation failed.' }
        # Review of STOP-TEXT-SPECIFIC-1: a ReadOnly lock refuses a delete with
        # the same ScopeLocked words, so a refusal during the move cannot tell
        # the lock type. Only the check before the move (the lock verdict) can.
        @{ Says = 'a delete under a lock'; Code = 'resourceLockRefused'; Message = "ScopeLocked: The scope '/subscriptions/x/resourceGroups/rg' cannot perform delete operation because following scope(s) are locked: '/subscriptions/x/resourceGroups/rg'." }
        @{ Says = 'CanNotDelete'; Code = 'resourceLockRefused'; Message = 'The resource is under a CanNotDelete lock.' }
        @{ Says = 'a write under a lock'; Code = 'resourceLockRefused'; Message = "ScopeLocked: The scope '/subscriptions/x/resourceGroups/rg' cannot perform write operation because following scope(s) are locked: '/subscriptions/x/resourceGroups/rg'." }
        @{ Says = 'ReadOnlyDisabledSubscription'; Code = 'subscriptionReadOnly'; Message = "ReadOnlyDisabledSubscription: The subscription '00000000-0000-0000-0000-000000000000' is disabled and therefore marked as read only." }
    ) {
        Script:Classify $Message | Should -Be $Code
    }

    It 'a quota failure still counts toward the wave''s capacity check, as it did when it was capacity' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sts-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $ids = 1..2 | ForEach-Object { "$script:sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm$_" }
        try {
            $plan = [pscustomobject]@{ entries = @($ids | ForEach-Object {
                [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $_; wave = 'w1'; path = 'A'; assessment = [pscustomobject]@{ location = 'centralus' }
                    target = [pscustomobject]@{ size = 'Standard_D2s_v6' } } }) }
            $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; ids = $ids; p = $plan } {
                Initialize-VmfRun -RunPath $rp -RunId 'sts' | Out-Null
                foreach ($id in $ids) {
                    New-VmfStateDoc -RunPath $rp -RunId 'sts' -VmId $id -Wave 'w1' | Out-Null
                    Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_ROLLED_BACK' -Outcome fail -MachineState 'restored' `
                        -Detail 'QuotaExceeded: exceeding approved standardDDSv6Family quota' -ReasonCode 'quotaExceeded' | Out-Null
                }
                Test-VmfCapacityExhausted -RunPath $rp -Plan $p -Wave 'w1'
            }
            $r.Exhausted | Should -BeTrue
            $r.Count | Should -Be 2
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }
}

Describe 'STOP-TEXT-SPECIFIC-1: a lock stop is the stop of its lock type' {
    BeforeAll {
        function Script:Verdict($locks) {
            InModuleScope VmMigrationFactory -Parameters @{ l = $locks } { Get-VmfLockVerdict -Locks $l }
        }
        $script:ro = [pscustomobject]@{ name = 'prod-guard'; level = 'ReadOnly'; scope = 'the resource group' }
        $script:nd = [pscustomobject]@{ name = 'no-delete'; level = 'CanNotDelete'; scope = 'the resource group' }
    }

    It 'a ReadOnly lock is resourceLocked' {
        (Script:Verdict @($script:ro)).Reason | Should -Be 'resourceLocked'
        (Script:Verdict @($script:ro, $script:nd)).Reason | Should -Be 'resourceLocked' -Because 'a ReadOnly lock refuses every change, the delete too'
    }

    It 'a CanNotDelete lock is no stop of the move (REBUILD-REMOVE-LEFTOVERS-1)' {
        # It was resourceDeleteLocked for the removed rebuild, which deleted the
        # machine definition.
        $v = Script:Verdict @($script:nd)
        $v.Blocked | Should -BeFalse
        $v.Reason | Should -BeNullOrEmpty
        $v.Detail | Should -Match 'no-delete'
    }

    It 'PRECHECK stops with the reason of the verdict' {
        $sm = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        $sm | Should -Match ([regex]::Escape("Reason = [string]`$lockVerdict.Reason"))
    }
}

Describe 'STOP-TEXT-SPECIFIC-1: the detail leads with what is missing, on which resource' {

    It 'the disk encryption sets: names each set, then the action on its scope' {
        $d = InModuleScope VmMigrationFactory -Parameters @{ a = $script:desCmk; b = $script:desDouble } {
            Format-VmfDiskEncryptionSetMissingMessage -Missing @(
                [pscustomobject]@{ Scope = $a; Action = 'Microsoft.Compute/diskEncryptionSets/read' }
                [pscustomobject]@{ Scope = $b; Action = 'Microsoft.Compute/diskEncryptionSets/read' })
        }
        $d | Should -Match ([regex]::Escape("The product's managed identity cannot read the disk encryption sets 'contoso-cmk' and 'contoso-double'."))
        $d | Should -Match ([regex]::Escape("Microsoft.Compute/diskEncryptionSets/read on $script:desCmk"))
        $d | Should -Match ([regex]::Escape("Microsoft.Compute/diskEncryptionSets/read on $script:desDouble"))
        $d | Should -Not -Match '(?i)subnet'
    }

    It 'the network: names the kind and the name of each linked resource' {
        $d = InModuleScope VmMigrationFactory -Parameters @{ s = $script:subnet; p = $script:pip } {
            Format-VmfLinkedMissingMessage -Missing @(
                [pscustomobject]@{ Scope = $s; Action = 'Microsoft.Network/virtualNetworks/subnets/join/action'; Kind = 'subnet' }
                [pscustomobject]@{ Scope = $p; Action = 'Microsoft.Network/publicIPAddresses/join/action'; Kind = 'publicIPAddress' })
        }
        $d | Should -Match ([regex]::Escape("The product's managed identity cannot join the subnet 'app' and the public IP address 'app-pip'"))
        $d | Should -Match ([regex]::Escape("Microsoft.Network/virtualNetworks/subnets/join/action on $script:subnet"))
    }

    It 'the network check passes the kind of each resource to the words' {
        $sm = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        $sm | Should -Match "(?s)function Test-VmfNicLinkedPermissions.{0,2600}Kind\s*="
    }

    It 'the user-assigned identity: names the identity' {
        $d = InModuleScope VmMigrationFactory -Parameters @{ m = $script:mi } {
            Format-VmfIdentityAssignMissingMessage -Missing @([pscustomobject]@{ Scope = $m; Action = 'Microsoft.ManagedIdentity/userAssignedIdentities/assign/action' })
        }
        $d | Should -Match ([regex]::Escape("The product's managed identity cannot assign the user-assigned managed identity 'app-mi'."))
        $d | Should -Match ([regex]::Escape('The run stopped before touching the machine. Grant the VMF Migration role where the managed identity is, then try again.') + '$')
    }

    It 'the machine: names the scope and each action' {
        $d = InModuleScope VmMigrationFactory -Parameters @{ v = $script:vmId } {
            Format-VmfMissingActionsMessage -Missing @('Microsoft.Compute/virtualMachines/delete', 'Microsoft.Compute/disks/write') -Scope $v
        }
        $d | Should -Match ([regex]::Escape("The product's managed identity does not have 2 permissions on the machine 'app01'"))
        $d | Should -Match ([regex]::Escape('Microsoft.Compute/virtualMachines/delete, Microsoft.Compute/disks/write'))
    }

    It 'no permission detail says "this identity" or "this account"' {
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'validate' 'Permissions.ps1') -Raw
        foreach ($fn in 'Format-VmfMissingActionsMessage', 'Format-VmfDiskEncryptionSetMissingMessage', 'Format-VmfIdentityAssignMissingMessage', 'Format-VmfLinkedMissingMessage') {
            $body = [regex]::Match($src, "(?s)function $fn\b.*?\r?\n\}").Value
            $body | Should -Not -BeNullOrEmpty
            ($body -split "`n" | Where-Object { $_ -match '^\s*"' -or $_ -match "^\s*'" -or $_ -match '\+\s*$' }) -join "`n" |
                Should -Not -Match '(?i)\bthis (identity|account)\b' -Because "$fn is shown to an operator"
        }
    }
}

Describe 'STOP-TEXT-SPECIFIC-1: the one-interface stop found in guest preparation says so' {

    It 'the detail of a stop from guest preparation says why the move turns it on' {
        $after = @{ On = 2; Unknown = 0 }
        $sku = [pscustomobject]@{ Name = 'Standard_D2s_v7'; Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = '2' }, [pscustomobject]@{ Name = 'vCPUsAvailable'; Value = '2' }) }
        $plain = InModuleScope VmMigrationFactory -Parameters @{ a = $after; s = $sku } { Get-VmfTargetAnFitRefusal -After $a -SkuEntry $s -TargetSize 'Standard_D2s_v7' }
        $plain.Reason | Should -Be 'targetOneAcceleratedNic'
        $plain.Detail | Should -Not -Match 'Linux Agent'
        $prep = InModuleScope VmMigrationFactory -Parameters @{ a = $after; s = $sku } { Get-VmfTargetAnFitRefusal -After $a -SkuEntry $s -TargetSize 'Standard_D2s_v7' -FoundInGuestPrep }
        $prep.Reason | Should -Be 'targetOneAcceleratedNic'
        $prep.Detail | Should -Match 'Azure Linux Agent'
        $prep.Detail | Should -Match 'MANA driver'
    }

    It 'guest preparation asks with that switch' {
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'TargetAnFit.ps1') -Raw
        [regex]::Match($src, '(?s)function Test-VmfGuestPrepAcceleratedNicsFit\b.*?\r?\n\}').Value | Should -Match 'Test-VmfTargetAcceleratedNicsFit[^\r\n]*-FoundInGuestPrep'
    }
}
