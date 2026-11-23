#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ID-ADDRESS-1 part 1: the engine finds what it changes by resource ID.
#
# The rule since 2026-09-28: never rely on a name alone. Two subscriptions can
# hold Azure resources with the same name; the resource ID is what matters.
# A name is unique only inside one resource group of one
# subscription. Each test below gives two resources the same name and proves
# the one the RECORDED ID names is the one acted on.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:subA = '00000000-0000-0000-0000-000000000000'
    $script:subB = '11111111-2222-3333-4444-555555555555'
}

Describe 'ID-ADDRESS-1: the OS disk is read through the ID the machine records for it' {
    It 'a disk in another resource group than the machine is found there, not by its name beside the machine' {
        InModuleScope VmMigrationFactory -Parameters @{ sub = $script:subA } {
            param($sub)
            Mock Get-AzVM { [pscustomobject]@{
                Id = "/subscriptions/$sub/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/vm1"
                StorageProfile = [pscustomobject]@{ DiskControllerType = 'SCSI'; OsDisk = [pscustomobject]@{
                    Name = 'osdisk'; ManagedDisk = [pscustomobject]@{ Id = "/subscriptions/$sub/resourceGroups/rg-disks/providers/Microsoft.Compute/disks/osdisk" } } } } }
            Mock Get-AzDisk { [pscustomobject]@{ Id = "/subscriptions/x/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/disks/$DiskName"; Location = 'centralus'; Sku = [pscustomobject]@{ Name = 'Premium_LRS' }; DiskSizeGB = 64 } }
            $info = Get-VmfOsDiskInfo -ResourceGroupName 'rg-vm' -Name 'vm1'
            Should -Invoke Get-AzDisk -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-disks' -and $DiskName -eq 'osdisk' }
            $info.resourceGroup | Should -Be 'rg-disks'
            $info.name | Should -Be 'osdisk'
        }
    }

    It 'a machine whose OS disk has no managed disk ID is refused, not guessed at' {
        InModuleScope VmMigrationFactory -Parameters @{ sub = $script:subA } {
            param($sub)
            Mock Get-AzVM { [pscustomobject]@{
                Id = "/subscriptions/$sub/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/vm1"
                StorageProfile = [pscustomobject]@{ OsDisk = [pscustomobject]@{ Name = 'osdisk'; ManagedDisk = $null } } } }
            Mock Get-AzDisk { throw 'must not be read by name' }
            { Get-VmfOsDiskInfo -ResourceGroupName 'rg-vm' -Name 'vm1' } | Should -Throw '*managed disk ID*'
            Should -Invoke Get-AzDisk -Times 0 -Exactly
        }
    }

    It 'a disk ID in another subscription than the machine is refused' {
        InModuleScope VmMigrationFactory -Parameters @{ subA = $script:subA; subB = $script:subB } {
            param($subA, $subB)
            Mock Get-AzVM { [pscustomobject]@{
                Id = "/subscriptions/$subA/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/vm1"
                StorageProfile = [pscustomobject]@{ OsDisk = [pscustomobject]@{
                    Name = 'osdisk'; ManagedDisk = [pscustomobject]@{ Id = "/subscriptions/$subB/resourceGroups/rg-disks/providers/Microsoft.Compute/disks/osdisk" } } } } }
            Mock Get-AzDisk { throw 'must not be read' }
            { Get-VmfOsDiskInfo -ResourceGroupName 'rg-vm' -Name 'vm1' } | Should -Throw '*subscription*'
        }
    }

    It 'a restore that keeps the name makes the new disk where the old one was' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Restore-VmfVm.ps1')
        $code | Should -Match '\$finalRg = if \(\$naming -eq ''preserve''\) \{ \$current\.resourceGroup \} else \{ \$rg \}'
        # SAFETY-CMK-1: through New-VmfOsDiskFromCopy, which passes both on.
        $code | Should -Match 'New-VmfOsDiskFromCopy [^\r\n]*\r?\n\s*-ResourceGroupName \$finalRg -DiskName \$finalName'
        $code | Should -Match 'Remove-VmfManagedDisk -ResourceGroupName \$current\.resourceGroup -DiskName \$current\.name'
    }
}

Describe 'ID-ADDRESS-1 with RESTORE-ALL-1: the data disks are read through the IDs the machine records' {
    It 'each data disk is found by its ID, in its own resource group, and named as the disk spells it; an unmanaged disk has no ID' {
        InModuleScope VmMigrationFactory -Parameters @{ sub = $script:subA } {
            param($sub)
            Mock Get-AzVM { [pscustomobject]@{
                Id = "/subscriptions/$sub/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/vm1"
                StorageProfile = [pscustomobject]@{ DataDisks = @(
                    [pscustomobject]@{ Lun = 0; Name = 'ignored'; ManagedDisk = [pscustomobject]@{ Id = "/subscriptions/$sub/resourceGroups/rg-data/providers/Microsoft.Compute/disks/DATA0"; StorageAccountType = 'Premium_LRS' } },
                    [pscustomobject]@{ Lun = 3; Name = 'vhd3'; ManagedDisk = $null }) } } }
            Mock Get-AzDisk { [pscustomobject]@{ Id = "/subscriptions/$sub/resourceGroups/$ResourceGroupName/providers/Microsoft.Compute/disks/data0"; Name = 'data0'; Sku = [pscustomobject]@{ Name = 'StandardSSD_LRS' } } }
            $disks = @(Get-VmfDataDiskInfo -ResourceGroupName 'rg-vm' -Name 'vm1')
            Should -Invoke Get-AzDisk -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-data' -and $DiskName -eq 'DATA0' }
            $disks[0].resourceGroup | Should -Be 'rg-data'
            $disks[0].name | Should -BeExactly 'data0'
            $disks[0].skuName | Should -Be 'StandardSSD_LRS'
            $disks[1].lun | Should -Be 3
            $disks[1].id | Should -Be ''
        }
    }

    It 'a data disk ID in another subscription than the machine is refused' {
        InModuleScope VmMigrationFactory -Parameters @{ subA = $script:subA; subB = $script:subB } {
            param($subA, $subB)
            Mock Get-AzVM { [pscustomobject]@{
                Id = "/subscriptions/$subA/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/vm1"
                StorageProfile = [pscustomobject]@{ DataDisks = @([pscustomobject]@{ Lun = 0; ManagedDisk = [pscustomobject]@{ Id = "/subscriptions/$subB/resourceGroups/rg-data/providers/Microsoft.Compute/disks/d0" } }) } } }
            Mock Get-AzDisk { throw 'must not be read' }
            { Get-VmfDataDiskInfo -ResourceGroupName 'rg-vm' -Name 'vm1' } | Should -Throw '*subscription*'
        }
    }
}
Describe 'ID-ADDRESS-1: a machine takes the capacity reservation of its OWN subscription' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-idaddr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'id-test' | Out-Null }
        $dir = Join-Path $script:runPath 'capacity'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($s in @(@{ n = 'a'; sub = $script:subA }, @{ n = 'b'; sub = $script:subB })) {
            $gid = "/subscriptions/$($s.sub)/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/vmf-id-test-w1-$($s.sub.Substring(0,8))"
            [ordered]@{ schemaVersion = 9; runId = 'id-test'; wave = 'w1'; subscriptionId = $s.sub; resourceGroup = 'rg-app'
                region = 'centralus'; zone = $null; size = 'Standard_D2s_v6'; state = 'RESERVED'
                reservation = @{ groupId = $gid; reservationId = "$gid/capacityReservations/d2s_v6" } } |
                ConvertTo-Json -Depth 6 | Set-Content (Join-Path $dir "$($s.n).json")
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'two claims alike but for the subscription: each machine gets its own' {
        foreach ($s in $script:subA, $script:subB) {
            $entry = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/subscriptions/$s/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1"; wave = 'w1'
                assessment = [pscustomobject]@{ location = 'centralus' }; target = [pscustomobject]@{ size = 'Standard_D2s_v6' } }
            $found = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; e = $entry } { param($rp, $e) Get-VmfClaimForEntry -RunPath $rp -Entry $e }
            $found.Claim.subscriptionId | Should -Be $s
            $found.Claim.reservation.groupId | Should -Match "^/subscriptions/$s/"
        }
    }

    It 'a claim whose reservation group is in another subscription than it says is not used' {
        $gid = "/subscriptions/$($script:subB)/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/vmf-odd"
        $c = Get-Content (Join-Path $script:runPath 'capacity' 'a.json') -Raw | ConvertFrom-Json
        $c.reservation.groupId = $gid
        $c | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:runPath 'capacity' 'a.json')
        $entry = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/subscriptions/$($script:subA)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1"; wave = 'w1'
            assessment = [pscustomobject]@{ location = 'centralus' }; target = [pscustomobject]@{ size = 'Standard_D2s_v6' } }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; e = $entry } { param($rp, $e) Get-VmfClaimForEntry -RunPath $rp -Entry $e } | Should -BeNullOrEmpty
    }

    It 'a claim that says another subscription than its group is not used either' {
        # Claim b says subscription B; point its group at A. A machine in A
        # must not take it: the two records of one reservation disagree.
        $c = Get-Content (Join-Path $script:runPath 'capacity' 'b.json') -Raw | ConvertFrom-Json
        $c.reservation.groupId = "/subscriptions/$($script:subA)/resourceGroups/rg-app/providers/Microsoft.Compute/capacityReservationGroups/vmf-odd"
        $c | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:runPath 'capacity' 'b.json')
        Remove-Item (Join-Path $script:runPath 'capacity' 'a.json')
        $entry = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/subscriptions/$($script:subA)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1"; wave = 'w1'
            assessment = [pscustomobject]@{ location = 'centralus' }; target = [pscustomobject]@{ size = 'Standard_D2s_v6' } }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; e = $entry } { param($rp, $e) Get-VmfClaimForEntry -RunPath $rp -Entry $e } | Should -BeNullOrEmpty
    }

    It 'no claim in the machine''s subscription is no claim, never the other one' {
        $entry = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1'; wave = 'w1'
            assessment = [pscustomobject]@{ location = 'centralus' }; target = [pscustomobject]@{ size = 'Standard_D2s_v6' } }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; e = $entry } { param($rp, $e) Get-VmfClaimForEntry -RunPath $rp -Entry $e } | Should -BeNullOrEmpty
    }
}

Describe 'ID-ADDRESS-1: a quota request goes to the claim''s subscription' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-idaddr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'id-test' | Out-Null }
        $script:dir = Join-Path $script:runPath 'capacity'
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        $script:claim = { param($sub) [ordered]@{ schemaVersion = 9; runId = 'id-test'; wave = 'w1'; subscriptionId = $sub; resourceGroup = 'rg-app'
            region = 'centralus'; zone = $null; size = 'Standard_D2s_v6'; vmFamily = 'standardDSv6Family'; state = 'BLOCKED'; blockReason = 'quota-shortfall'
            demand = @{ vcpus = 4 }; quota = @{ limit = 10; used = 8; requestId = $null; requestedUtc = $null }; notes = @() } }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'the request names the subscription the claim records, not the session''s' {
        & $script:claim $script:subB | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:dir 'c.json')
        Mock -ModuleName VmMigrationFactory Get-VmfCurrentSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
        Request-VmfQuota -OutPath $script:runPath | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Request-VmfQuotaIncrease -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq '11111111-2222-3333-4444-555555555555' }
    }

    It 'a claim that cannot say its subscription is not requested anywhere' {
        & $script:claim $null | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:dir 'c.json')
        Mock -ModuleName VmMigrationFactory Get-VmfCurrentSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
        $r = Request-VmfQuota -OutPath $script:runPath
        Should -Invoke -ModuleName VmMigrationFactory Request-VmfQuotaIncrease -Times 0 -Exactly
        @($r.Failed).Count | Should -Be 1
    }
}

Describe 'ID-ADDRESS-1 review: the smaller gaps' {
    It 'a machine with no ID of its own is refused, not read in the session''s subscription' {
        InModuleScope VmMigrationFactory -Parameters @{ sub = $script:subA } {
            param($sub)
            Mock Get-AzVM { [pscustomobject]@{ Id = $null
                StorageProfile = [pscustomobject]@{ OsDisk = [pscustomobject]@{
                    Name = 'osdisk'; ManagedDisk = [pscustomobject]@{ Id = "/subscriptions/$sub/resourceGroups/rg-disks/providers/Microsoft.Compute/disks/osdisk" } } } } }
            Mock Get-AzDisk { throw 'must not be read' }
            { Get-VmfOsDiskInfo -ResourceGroupName 'rg-vm' -Name 'vm1' } | Should -Throw '*subscription*'
        }
    }

    It 'the name is the disk''s own spelling, not the ID''s' {
        InModuleScope VmMigrationFactory -Parameters @{ sub = $script:subA } {
            param($sub)
            Mock Get-AzVM { [pscustomobject]@{
                Id = "/subscriptions/$sub/resourceGroups/rg-vm/providers/Microsoft.Compute/virtualMachines/vm1"
                StorageProfile = [pscustomobject]@{ OsDisk = [pscustomobject]@{
                    Name = 'OsDisk'; ManagedDisk = [pscustomobject]@{ Id = "/subscriptions/$sub/resourceGroups/RG-DISKS/providers/Microsoft.Compute/disks/OSDISK" } } } } }
            Mock Get-AzDisk { [pscustomobject]@{ Name = 'OsDisk'; Id = 'x'; Location = 'centralus'; Sku = [pscustomobject]@{ Name = 'Premium_LRS' }; DiskSizeGB = 64 } }
            (Get-VmfOsDiskInfo -ResourceGroupName 'rg-vm' -Name 'vm1').name | Should -BeExactly 'OsDisk'
        }
    }

    It 'a machine with no reservation of its own, in a wave that has one of its size, is said' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $code | Should -Match '(?s)elseif \(-not \$reservedClaim\) \{.*?Outcome warn.*?moves with no capacity reservation'
    }

    It 'the engine says how many quota requests were made and how many failed' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1')
        $code | Should -Match '\$\(@\(\$r\.Submitted\)\.Count\) request\(s\) submitted, \$\(@\(\$r\.Failed\)\.Count\) failed'
    }
}

Describe 'ID-ADDRESS-1 review: a subscription that is not an ID is not requested' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-idaddr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'id-test' | Out-Null }
        New-Item -ItemType Directory -Path (Join-Path $script:runPath 'capacity') -Force | Out-Null
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'a claim naming something that is not a subscription ID asks nobody' {
        [ordered]@{ schemaVersion = 9; runId = 'id-test'; wave = 'w1'; subscriptionId = 'rg-app/../x'; resourceGroup = 'rg-app'
            region = 'centralus'; zone = $null; size = 'Standard_D2s_v6'; vmFamily = 'standardDSv6Family'; state = 'BLOCKED'; blockReason = 'quota-shortfall'
            demand = @{ vcpus = 4 }; quota = @{ limit = 10; used = 8; requestId = $null; requestedUtc = $null }; notes = @() } |
            ConvertTo-Json -Depth 6 | Set-Content (Join-Path $script:runPath 'capacity' 'c.json')
        Mock -ModuleName VmMigrationFactory Request-VmfQuotaIncrease { [pscustomobject]@{ StatusCode = 200; Content = '{}' } }
        $r = Request-VmfQuota -OutPath $script:runPath
        Should -Invoke -ModuleName VmMigrationFactory Request-VmfQuotaIncrease -Times 0 -Exactly
        @($r.Failed).Count | Should -Be 1
    }
}

# ID-ADDRESS-1 part 2: the tools and hooks. Each test gives two things one name
# and proves the one the RECORDED ID or the NAMED SUBSCRIPTION points at is the
# one acted on.
Describe 'ID-ADDRESS-1 part 2: a registration is found by the application ID the install recorded' {
    BeforeAll {
        . (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRegistration.ps1')
        $script:apiA = @{ id = 'object-a1'; appId = 'aaaaaaaa-0000-4000-8000-000000000001'; displayName = 'vmf-api-idtest' }
        $script:apiB = @{ id = 'object-a2'; appId = 'aaaaaaaa-0000-4000-8000-000000000002'; displayName = 'vmf-api-idtest' }
        $script:dash = @{ id = 'object-d1'; appId = 'dddddddd-0000-4000-8000-000000000001'; displayName = 'vmf-dashboard-idtest' }
    }

    It 'takes the application with that ID, and asks the directory by the ID' {
        $global:idApps = @($script:apiA, $script:apiB)
        function az { $global:idSeen = @($args); $global:LASTEXITCODE = 0
            $id = $args[[array]::IndexOf($args, '--app-id') + 1]
            $global:idApps | Where-Object { $_.appId -eq $id } | ConvertTo-Json -AsArray -Depth 4 }
        $app = Get-VmfEntraApplicationByAppId -AppId 'aaaaaaaa-0000-4000-8000-000000000002' -DisplayName 'vmf-api-idtest'
        $app.id | Should -Be 'object-a2'
        $global:idSeen | Should -Contain '--app-id'
        $global:idSeen | Should -Not -Contain '--display-name'
    }

    It 'refuses the application with that ID when it carries another name' {
        $global:idApps = @(@{ id = 'object-x'; appId = 'aaaaaaaa-0000-4000-8000-000000000001'; displayName = 'contoso-payroll' })
        function az { $global:LASTEXITCODE = 0
            $id = $args[[array]::IndexOf($args, '--app-id') + 1]
            $global:idApps | Where-Object { $_.appId -eq $id } | ConvertTo-Json -AsArray -Depth 4 }
        { Get-VmfEntraApplicationByAppId -AppId 'aaaaaaaa-0000-4000-8000-000000000001' -DisplayName 'vmf-api-idtest' } |
            Should -Throw "*named 'contoso-payroll', not 'vmf-api-idtest'*"
    }

    It 'no application with that ID is an empty answer; a failed call is a failure' {
        function az { $global:LASTEXITCODE = 0; '[]' }
        Get-VmfEntraApplicationByAppId -AppId 'aaaaaaaa-0000-4000-8000-000000000009' -DisplayName 'vmf-api-idtest' | Should -BeNullOrEmpty
        function az { $global:LASTEXITCODE = 1 }
        { Get-VmfEntraApplicationByAppId -AppId 'aaaaaaaa-0000-4000-8000-000000000009' -DisplayName 'vmf-api-idtest' } | Should -Throw '*FAILED*'
    }

    It 'a value that is not an application ID is refused before it is sent' {
        function az { throw 'must not be called' }
        { Get-VmfEntraApplicationByAppId -AppId 'vmf-api-idtest' -DisplayName 'vmf-api-idtest' } | Should -Throw '*not an application id*'
    }

    Context 'the uninstall hook, run with a stand-in for az and azd' {
        BeforeEach {
            $script:envKeys = 'AZURE_ENV_NAME', 'VMF_REMOVE_REGISTRATIONS', 'VMF_API_APP_ID', 'VMF_DASHBOARD_APP_ID',
                'VMF_API_DISPLAY_NAME', 'VMF_DASHBOARD_DISPLAY_NAME', 'VMF_REGISTRATION_KEY',
                'AZURE_SUBSCRIPTION_ID', 'AZURE_RESOURCE_GROUP', 'VMF_DOWN_RESOURCE_GROUP'
            $script:envBefore = @{}
            foreach ($k in $script:envKeys) { $script:envBefore[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $null) }
            [Environment]::SetEnvironmentVariable('AZURE_ENV_NAME', 'idtest')
            # AZD-DOWN-RG-RECHECK-1: postdown removes nothing until Azure says
            # the resource group is gone. Here it is gone (the stand-in below);
            # AzdDownRecheck.Tests.ps1 holds the other answers.
            [Environment]::SetEnvironmentVariable('AZURE_SUBSCRIPTION_ID', $script:subA)
            [Environment]::SetEnvironmentVariable('VMF_DOWN_RESOURCE_GROUP', 'rg-idtest')
            [Environment]::SetEnvironmentVariable('VMF_REMOVE_REGISTRATIONS', 'yes')
            $global:idDeleted = @()
            $global:idByName = @()
            $global:idFailById = $false
            function global:azd { $global:LASTEXITCODE = 0 }
            function global:az {
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'group' -and $args[1] -eq 'show') {
                    Write-Error "(ResourceGroupNotFound) Resource group 'rg-idtest' could not be found."
                    $global:LASTEXITCODE = 3; return
                }
                if ($args[0] -eq 'ad' -and $args[2] -eq 'delete') { $global:idDeleted += [string]$args[[array]::IndexOf($args, '--id') + 1]; return }
                if ($args -contains '--app-id') {
                    if ($global:idFailById) { $global:LASTEXITCODE = 1; return }
                    $id = $args[[array]::IndexOf($args, '--app-id') + 1]
                    return ($global:idApps | Where-Object { $_.appId -eq $id } | ConvertTo-Json -AsArray -Depth 4)
                }
                if ($args -contains '--display-name') {
                    $n = $args[[array]::IndexOf($args, '--display-name') + 1]
                    $global:idByName += $n
                    return ($global:idApps | Where-Object { $_.displayName -like "$n*" } | ConvertTo-Json -AsArray -Depth 4)
                }
                '[]'
            }
            $script:runDown = { & (Join-Path $script:repoRoot 'infra' 'hooks' 'postdown.ps1') 6>&1 | Out-String }
        }
        AfterEach {
            foreach ($k in $script:envKeys) { [Environment]::SetEnvironmentVariable($k, $script:envBefore[$k]) }
            # `function:global:az` removes nothing (the review measured it), so
            # the stand-ins would reach every later test file.
            Remove-Item function:az, function:azd -ErrorAction SilentlyContinue
            Remove-Variable -Scope Global -Name idApps, idDeleted, idByName, idFailById, idSeen -ErrorAction SilentlyContinue
        }

        It 'deletes the recorded registrations, and never the other one with the same name' {
            # By name alone this refused: two registrations carry vmf-api-idtest.
            $global:idApps = @($script:apiA, $script:apiB, $script:dash)
            [Environment]::SetEnvironmentVariable('VMF_API_APP_ID', $script:apiB.appId)
            [Environment]::SetEnvironmentVariable('VMF_DASHBOARD_APP_ID', $script:dash.appId)
            $said = & $script:runDown
            $global:idDeleted | Should -Be @('object-a2', 'object-d1')
            $global:idByName | Should -BeNullOrEmpty
            $said | Should -Match 'removed vmf-api-idtest'
            # The ids go with the registrations, so the next removal cannot
            # look for one that is gone.
            [Environment]::GetEnvironmentVariable('VMF_API_APP_ID') | Should -BeNullOrEmpty
            [Environment]::GetEnvironmentVariable('VMF_DASHBOARD_APP_ID') | Should -BeNullOrEmpty
        }

        It 'a recorded ID whose registration now has another name is left, and said' {
            $global:idApps = @(@{ id = 'object-x'; appId = $script:apiA.appId; displayName = 'contoso-payroll' }, $script:dash)
            [Environment]::SetEnvironmentVariable('VMF_API_APP_ID', $script:apiA.appId)
            [Environment]::SetEnvironmentVariable('VMF_DASHBOARD_APP_ID', $script:dash.appId)
            $said = & $script:runDown
            $global:idDeleted | Should -Be @('object-d1')
            $said | Should -Match "vmf-api-idtest is left in place: .*named 'contoso-payroll'"
            # Left in place keeps its id, so the next removal finds it again.
            [Environment]::GetEnvironmentVariable('VMF_API_APP_ID') | Should -Be $script:apiA.appId
            [Environment]::GetEnvironmentVariable('VMF_DASHBOARD_APP_ID') | Should -BeNullOrEmpty
        }

        It 'a recorded ID with no registration is not found, and the one that has only the name is left' {
            $global:idApps = @($script:apiB, $script:dash)
            [Environment]::SetEnvironmentVariable('VMF_API_APP_ID', $script:apiA.appId)
            [Environment]::SetEnvironmentVariable('VMF_DASHBOARD_APP_ID', $script:dash.appId)
            $said = & $script:runDown
            $global:idDeleted | Should -Be @('object-d1')
            $said | Should -Match 'vmf-api-idtest was not found'
            $global:idByName | Should -BeNullOrEmpty
            [Environment]::GetEnvironmentVariable('VMF_API_APP_ID') | Should -BeNullOrEmpty
        }

        It 'a directory call that fails leaves the registration, and deletes nothing on a guess' {
            $global:idApps = @($script:apiA, $script:dash)
            $global:idFailById = $true
            [Environment]::SetEnvironmentVariable('VMF_API_APP_ID', $script:apiA.appId)
            [Environment]::SetEnvironmentVariable('VMF_DASHBOARD_APP_ID', $script:dash.appId)
            $said = & $script:runDown
            $global:idDeleted | Should -BeNullOrEmpty
            $said | Should -Match 'vmf-api-idtest is left in place'
            $global:idByName | Should -BeNullOrEmpty
        }

        It 'with no ID recorded, the exact-name lookup is the answer' {
            $global:idApps = @($script:apiA, $script:dash)
            & $script:runDown | Out-Null
            $global:idDeleted | Should -Be @('object-a1', 'object-d1')
            $global:idByName | Should -Be @('vmf-api-idtest', 'vmf-dashboard-idtest')
        }
    }
}

Describe 'ID-ADDRESS-1 part 2: the grant script works in ONE named subscription, on ONE identity of each kind' {
    BeforeAll {
        $script:grantPath = Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1'
        $script:grantCode = Get-VmfCodeOnly -Path $script:grantPath
        $script:grantAst = [System.Management.Automation.Language.Parser]::ParseFile($script:grantPath, [ref]$null, [ref]$null)
        # Part 3: the rule moved to infra/Resolve-VmfRegistration.ps1, which
        # the grant script dot-sources, so every tool uses one copy of it.
        . (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRegistration.ps1')
        $script:pickOne = { param($Items, $Exact, $Prefix, $What, $NameParameter)
            Select-VmfOneByName -Items $Items -Exact $Exact -Prefix $Prefix -What $What -NameParameter $NameParameter -ResourceGroup $ResourceGroup -Use 'grant' }
    }

    It 'two identities whose names start alike are refused, never the first one listed' {
        $ResourceGroup = 'rg-vmf'
        $items = @([pscustomobject]@{ name = 'vmf-engine-mi-aaaa'; principalId = 'p1' }, [pscustomobject]@{ name = 'vmf-engine-mi-bbbb'; principalId = 'p2' })
        { & $script:pickOne $items '' 'vmf-engine-mi' 'managed identities' 'EngineIdentityName' } |
            Should -Throw '*holds 2 managed identities*does not guess*-EngineIdentityName*'
    }

    It 'one identity is the answer, and none is nothing' {
        $ResourceGroup = 'rg-vmf'
        $one = @([pscustomobject]@{ name = 'vmf-engine-mi-aaaa'; principalId = 'p1' }, [pscustomobject]@{ name = 'contoso-mi'; principalId = 'p9' })
        (& $script:pickOne $one '' 'vmf-engine-mi' 'managed identities' 'EngineIdentityName').principalId | Should -Be 'p1'
        & $script:pickOne @([pscustomobject]@{ name = 'contoso-mi' }) '' 'vmf-engine-mi' 'managed identities' 'EngineIdentityName' | Should -BeNullOrEmpty
    }

    It 'an exact name picks that one, where a prefix matches two (a plan change leaves the old facade)' {
        $ResourceGroup = 'rg-vmf'
        $two = @([pscustomobject]@{ name = 'vmf-facade-aaaa'; identity = @{ principalId = 'old' } },
                 [pscustomobject]@{ name = 'vmf-facade-b1-aaaa'; identity = @{ principalId = 'new' } })
        (& $script:pickOne $two 'vmf-facade-b1-aaaa' 'vmf-facade' 'function apps' 'FacadeName').identity.principalId | Should -Be 'new'
    }

    Context 'the script, run with a stand-in for az' {
        BeforeEach {
            $script:grantRun = { param([hashtable]$Arguments) & $script:grantPath @Arguments 6>&1 | Out-String }
        }
        AfterEach { Remove-Item function:az -ErrorAction SilentlyContinue }

        It 'a listing that fails stops a grant with the reason, not "found no identities"' {
            function az { $global:LASTEXITCODE = 1 }
            { & $script:grantRun @{ ResourceGroup = 'rg-vmf'; SubscriptionId = $script:subA; MigrateScope = "/subscriptions/$($script:subA)" } } |
                Should -Throw "*Could not list the managed identities in 'rg-vmf' in subscription $($script:subA)*"
        }

        It 'closing the gate alone does not read the identities, so it needs no role on the resource group' {
            function az {
                if ($args[0] -in 'identity', 'functionapp') { throw 'the identities must not be read' }
                $global:LASTEXITCODE = 0; '[]'
            }
            # It stops later, at the registration this stand-in does not hold.
            { & $script:grantRun @{ ResourceGroup = 'rg-vmf'; SubscriptionId = $script:subA; CloseTheGate = $true } } |
                Should -Throw '*No registration whose name starts*'
        }

        It 'a value that is not a subscription ID is refused before any call' {
            function az { throw 'must not be called' }
            { & $script:grantRun @{ ResourceGroup = 'rg-vmf'; SubscriptionId = 'contoso-sub'; MigrateScope = '/subscriptions/x' } } |
                Should -Throw "*'contoso-sub' is not a subscription ID*"
        }
    }

    It 'every az call that names a resource group names the subscription too' {
        $calls = @($script:grantAst.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] -and $args[0].GetCommandName() -eq 'az' }, $true))
        $withGroup = @($calls | Where-Object { $_.Extent.Text -match '\s-g\s|\s-n \$ResourceGroup' })
        $withGroup.Count | Should -BeGreaterOrEqual 3
        foreach ($c in $withGroup) { $c.Extent.Text | Should -Match '--subscription \$SubscriptionId' -Because $c.Extent.Text }
    }

    It 'the CLI''s current subscription is read once, only when none is given, and said' {
        ([regex]::Matches($script:grantCode, 'az account show')).Count | Should -Be 1
        $script:grantCode | Should -Match '(?s)if \(-not \$SubscriptionId\) \{\s*\$SubscriptionId = az account show'
        $script:grantCode | Should -Match "the Azure CLI's current one"
        $script:grantCode | Should -Match 'is not a subscription ID'
    }

    It 'a listing that fails is said, never read as an empty resource group' {
        # INSTALL-THROTTLE-RETRY-2: through Invoke-VmfAzCall, same words.
        $script:grantCode | Should -Match 'if \(\$idRead\.ExitCode -ne 0\) \{ throw \("Could not list the managed identities'
        $script:grantCode | Should -Match 'if \(\$appRead\.ExitCode -ne 0\) \{ throw \("Could not list the function apps'
    }

    It 'the install passes its own subscription to it' {
        $post = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'postprovision.ps1')
        $post | Should -Match '\$grantArgs = @\{ ResourceGroup = \$rg; SubscriptionId = \$subId; FacadeName = \$facade \}'
        $post | Should -Match '\$grantArgs\.EngineIdentityName = "vmf-engine-mi-\$baseSuffix"'
        # The dashboard is pointed at the facade the install made, not the
        # first one whose name starts alike.
        $post | Should -Match '-ApiDisplayName \$names\.Api -FacadeName \$facade'
        $dash = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1')
        # Part 3: by the exact name, through the rule every tool uses.
        $dash | Should -Match "Select-VmfOneByName -Items \`$facadeApps -Exact \`$FacadeName"
        $dash | Should -Match 'if \(\$FacadeName -and -not \$facadeSite\) \{ throw'
        # The name the template gives it, so the two cannot drift apart unseen.
        Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw | Should -Match "var engineIdentityName = 'vmf-engine-mi-\$\{baseSuffix\}'"
    }

    It 'the install blanks the recorded registration ids before it deploys them, and records both after' {
        $pre = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1')
        $blank = $pre.IndexOf("Set-AzdValue -Name 'VMF_API_APP_ID' -Value ''")
        $deploy = $pre.IndexOf("identity-deploy.ps1') @identityArgs")
        $blank | Should -BeGreaterThan 0
        $blank | Should -BeLessThan $deploy
        $pre.IndexOf("Set-AzdValue -Name 'VMF_DASHBOARD_APP_ID' -Value ''") | Should -BeLessThan $deploy
        $pre | Should -Match "(?m)^Set-AzdValue -Name 'VMF_DASHBOARD_APP_ID' -Value \`$dashboardAppId"
    }
}

Describe 'ID-ADDRESS-1 part 2: what the install and the removal say about the subscription' {
    It 'the readiness check says the Azure CLI stays on the subscription it switched to' {
        $ready = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'Test-VmfReadiness.ps1')
        $ready | Should -Match 'switched the Azure CLI from subscription \$\(\$acct\.id\) to \$SubscriptionId'
        $ready | Should -Match 'It stays on that subscription after the install'
    }

    It 'the removal says which subscription it counted in, and that others are not counted' {
        $down = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'infra' 'hooks' 'predown.ps1')
        $down | Should -Match 'locked safety copies in \$\(if \(\$subscription\) \{ "subscription \$subscription" \} else \{ "the install''s subscription" \}\): \$countText'
        $down | Should -Match 'Machines in other subscriptions keep their copies there'
        $down | Should -Match 'capacity reservation groups this product made, in \$\(if \(\$subscription\)'
    }

    It 'with no subscription set, the removal names the install''s subscription, never an empty one' {
        $downText = Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'predown.ps1') -Raw
        $section = [regex]::Match($downText, "(?s)Write-Step 'Capacity reservations'.*?(?=# TEARDOWN-1)").Value
        $run = [scriptblock]::Create("function Write-Step { param(`$Name) }`n" + $section)
        function az { throw 'must not be called' }
        $subscription = ''
        $reservationCannotCount = ''
        $said = . $run 6>&1 | Out-String
        $said | Should -Match "made, in the install's subscription: not counted, because AZURE_SUBSCRIPTION_ID is not set"
        $said | Should -Not -Match 'in subscription :'
    }
}

# ---- part 3: the size catalog, and the last name-prefix lookups ------------

Describe 'ID-ADDRESS-1 part 3: the size catalog belongs to a subscription AND a region' {
    BeforeAll {
        function Global:Ia3Id([string]$Sub, [string]$Name = 'app1') {
            "/subscriptions/$Sub/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
        }
        function Global:Ia3Sku([string]$Name, [object[]]$Restrictions = @(), [string]$Gens = 'V1,V2') {
            [pscustomobject]@{ Name = $Name; Family = 'standardDSv6Family'; ResourceType = 'virtualMachines'; Restrictions = @($Restrictions)
                Capabilities = @(
                    [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }
                    [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                    [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                    [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                    [pscustomobject]@{ Name = 'MemoryGB'; Value = '8' }
                    [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
        }
        # Azure's own shape for a size the subscription may not use in the region.
        $script:notForSub = [pscustomobject]@{ Type = 'Location'; ReasonCode = 'NotAvailableForSubscription'
            Values = @('centralus'); RestrictionInfo = [pscustomobject]@{ Locations = @('centralus'); Zones = @() } }
        # Two machines with ONE name, in one resource group name, in one
        # region - in two subscriptions. Only the subscription tells them apart.
        $script:vmA = Ia3Id $script:subA
        $script:vmB = Ia3Id $script:subB
    }
    AfterAll { Remove-Item 'function:\Ia3Id', 'function:\Ia3Sku' -ErrorAction SilentlyContinue }

    Context 'the reads, one for each subscription and region' {
        It 'two subscriptions give the same region different restrictions: each machine gets its own' {
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
                if ($SubscriptionId -eq '11111111-2222-3333-4444-555555555555') { @(Ia3Sku 'Standard_D2s_v6' -Restrictions @($script:notForSub)) }
                else { @(Ia3Sku 'Standard_D2s_v6') }
            }
            $c = InModuleScope VmMigrationFactory -Parameters @{ a = $script:vmA; b = $script:vmB } {
                param($a, $b)
                $all = Read-VmfMachineCatalogs -Machines @([pscustomobject]@{ vmId = $a; location = 'centralus' }, [pscustomobject]@{ vmId = $b; location = 'CentralUS' }) -IdProperty 'vmId'
                @{ A = (Get-VmfMachineCatalog -Catalogs $all -VmId $a -Location 'centralus'); B = (Get-VmfMachineCatalog -Catalogs $all -VmId $b -Location 'centralus') }
            }
            @($c.A['Standard_D2s_v6'].Restrictions).Count | Should -Be 0 -Because 'subscription A may use the size'
            @($c.B['Standard_D2s_v6'].Restrictions)[0].ReasonCode | Should -Be 'NotAvailableForSubscription' -Because 'subscription B may not'
            Should -Invoke -ModuleName VmMigrationFactory Get-VmfSkuCatalog -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq '00000000-0000-0000-0000-000000000000' }
            Should -Invoke -ModuleName VmMigrationFactory Get-VmfSkuCatalog -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq '11111111-2222-3333-4444-555555555555' }
            Should -Invoke -ModuleName VmMigrationFactory Get-VmfSkuCatalog -Times 0 -Exactly -ParameterFilter { -not $SubscriptionId }
        }

        It 'machines of one subscription and region are one read' {
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @(Ia3Sku 'Standard_D2s_v6') }
            InModuleScope VmMigrationFactory -Parameters @{ a = $script:vmA; a2 = (Ia3Id $script:subA 'app2') } {
                param($a, $a2)
                $null = Read-VmfMachineCatalogs -Machines @([pscustomobject]@{ vmId = $a; location = 'centralus' }, [pscustomobject]@{ vmId = $a2; location = 'centralus' }) -IdProperty 'vmId'
            }
            Should -Invoke -ModuleName VmMigrationFactory Get-VmfSkuCatalog -Times 1 -Exactly
        }

        It 'a machine never gets the catalog of another subscription: none read is none, not the other one' {
            InModuleScope VmMigrationFactory -Parameters @{ a = $script:vmA; b = $script:vmB } {
                param($a, $b)
                $all = @{ (Get-VmfCatalogKey -VmId $a -Location 'centralus') = @{ 'Standard_D2s_v6' = 'a' } }
                Get-VmfMachineCatalog -Catalogs $all -VmId $b -Location 'centralus' | Should -BeNullOrEmpty
                (Get-VmfMachineCatalog -Catalogs $all -VmId $a -Location 'CENTRALUS')['Standard_D2s_v6'] | Should -Be 'a'
            }
        }

        It 'a read that fails is listed when the caller collects them, and stops the caller otherwise' {
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
                if ($SubscriptionId -eq '11111111-2222-3333-4444-555555555555') { throw 'AuthorizationFailed' }
                @(Ia3Sku 'Standard_D2s_v6')
            }
            InModuleScope VmMigrationFactory -Parameters @{ a = $script:vmA; b = $script:vmB } {
                param($a, $b)
                $machines = @([pscustomobject]@{ vmId = $a; location = 'centralus' }, [pscustomobject]@{ vmId = $b; location = 'centralus' })
                $notRead = [System.Collections.Generic.List[string]]::new()
                $all = Read-VmfMachineCatalogs -Machines $machines -IdProperty 'vmId' -NotRead $notRead
                @($notRead) | Should -Be @(Get-VmfCatalogKey -VmId $b -Location 'centralus')
                Get-VmfMachineCatalog -Catalogs $all -VmId $b -Location 'centralus' | Should -BeNullOrEmpty
                Get-VmfMachineCatalog -Catalogs $all -VmId $a -Location 'centralus' | Should -Not -BeNullOrEmpty
                { Read-VmfMachineCatalogs -Machines $machines -IdProperty 'vmId' } | Should -Throw '*AuthorizationFailed*'
            }
        }

        It 'every read of the catalog in the module names the subscription' {
            # A read with no subscription is a read in whatever subscription the
            # session is in, cached for every machine in the region.
            $files = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Recurse -Filter '*.ps1')
            $calls = foreach ($f in $files) {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
                $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-VmfSkuCatalog' }, $true) |
                    ForEach-Object { [pscustomobject]@{ File = $f.Name; Line = $_.Extent.StartLineNumber
                        Named = [bool]@($_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'SubscriptionId' }).Count } }
            }
            @($calls).Count | Should -BeGreaterThan 5 -Because 'the check must find the reads it is about'
            @($calls | Where-Object { -not $_.Named } | ForEach-Object { "$($_.File):$($_.Line)" }) | Should -BeNullOrEmpty
        }
    }

    Context 'the quota check' {
        BeforeEach {
            $script:qRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ia3q-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path $script:qRun -Force | Out-Null
            @{ schemaVersion = 1; assessmentRunId = 'r1'; entries = @(
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmA; wave = 'wave-1'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2s_v6' } },
                @{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmB; wave = 'wave-1'; path = 'A'; assessment = @{ location = 'centralus' }; target = @{ size = 'Standard_D2s_v6' } })
            } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:qRun 'plan.json')
            Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
                @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardDSv6Family' }; CurrentValue = 0; Limit = 10 })
            }
            Mock -ModuleName VmMigrationFactory Get-VmfRetailPrice { $null }
        }
        AfterEach { if (Test-Path $script:qRun) { Remove-Item $script:qRun -Recurse -Force } }

        It 'judges each machine on the restrictions of its own subscription' {
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
                if ($SubscriptionId -eq '11111111-2222-3333-4444-555555555555') { @(Ia3Sku 'Standard_D2s_v6' -Restrictions @($script:notForSub)) }
                else { @(Ia3Sku 'Standard_D2s_v6') }
            }
            $r = Test-VmfQuota -PlanPath (Join-Path $script:qRun 'plan.json') -OutPath $script:qRun
            $a = @($r.Claims) | Where-Object subscriptionId -EQ $script:subA
            $b = @($r.Claims) | Where-Object subscriptionId -EQ $script:subB
            $a.state | Should -Be 'QUOTA_VERIFIED'
            $b.state | Should -Be 'BLOCKED'
            $b.blockReason | Should -Be 'sku-restricted'
            ($b.notes -join ' ') | Should -Match 'NotAvailableForSubscription'
        }
    }

    Context 'the scan, the target options and the plan' {
        BeforeAll {
            function Global:Ia3Assessed([string]$VmId) {
                [ordered]@{ vmId = $VmId; name = 'app1'; resourceGroup = 'rg-app'; location = 'centralus'; zones = @()
                    classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; osVersion = '22_04-lts'
                    sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; sourceTempDisks = 0; diskController = 'SCSI'; dataDiskCount = 1; nicCount = 1
                    acceleratedNicCount = 1; primaryNicAccelerated = $true; platformManaged = $false; iacManaged = $false; hibernationEnabled = $false
                    availabilitySetId = ''; identityType = 'None'; tags = @{ app = 'app1' }; blockers = @(); prepNeeded = @() }
            }
            # Subscription B is not offered the v6 size in the region; A is.
            $script:catalogMock = {
                $sizes = @('Standard_D2s_v4', 'Standard_D2s_v5', 'Standard_D2s_v6', 'Standard_D2s_v7')
                if ($SubscriptionId -eq '11111111-2222-3333-4444-555555555555') { $sizes = @($sizes | Where-Object { $_ -ne 'Standard_D2s_v6' }) }
                @($sizes | ForEach-Object { Ia3Sku $_ })
            }
        }
        AfterAll { Remove-Item 'function:\Ia3Assessed' -ErrorAction SilentlyContinue }
        BeforeEach {
            $script:sRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ia3s-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            # B, then A, then B again: the target options keep the order of the
            # scan, not the order of the subscriptions.
            $script:vmB2 = Ia3Id $script:subB 'app2'
            $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $script:sRun -Leaf); generatedUtc = '2026-11-07T00:00:00Z'
                scope = @{ subscriptions = @() }; summary = @{}; vms = @((Ia3Assessed $script:vmB), (Ia3Assessed $script:vmA), (Ia3Assessed $script:vmB2)) }
            InModuleScope VmMigrationFactory -Parameters @{ r = $script:sRun; d = $doc } {
                param($r, $d)
                Initialize-VmfRun -RunPath $r -RunId (Split-Path $r -Leaf) -Kind 'assessment' | Out-Null
                Write-VmfStoreJson -RunPath $r -RelPath 'assessment.json' -Document $d -Depth 24
            }
            Approve-VmfAssessment -RunPath $script:sRun -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog $script:catalogMock
        }
        AfterEach {
            foreach ($d in $script:sRun, "$($script:sRun)-migration") { if ($d -and (Test-Path $d)) { [System.IO.Directory]::Delete($d, $true) } }
        }

        It 'the target options give each machine the sizes of its own subscription, in the order of the scan' {
            New-VmfTargetAdvice -AssessmentPath (Join-Path $script:sRun 'assessment.json') | Out-Null
            $advice = Get-Content (Join-Path $script:sRun 'target-advice.json') -Raw | ConvertFrom-Json -Depth 30
            @($advice.machines | ForEach-Object { $_.vmId }) | Should -Be @($script:vmB, $script:vmA, $script:vmB2)
            $v6 = { param($m) @($m.options | Where-Object { $_.option -eq 'v6' })[0] }
            (& $v6 $advice.machines[1]).targetSize | Should -Be 'Standard_D2s_v6' -Because 'subscription A is offered it'
            (& $v6 $advice.machines[0]).targetSize | Should -Not -Be 'Standard_D2s_v6' -Because 'subscription B is not'
            @($advice.regions).Count | Should -Be 1
            $advice.regions[0].read | Should -BeTrue
            $advice.schemaVersion | Should -Not -BeNullOrEmpty
            Should -Invoke -ModuleName VmMigrationFactory Get-VmfSkuCatalog -Times 0 -Exactly -ParameterFilter { -not $SubscriptionId }
        }

        It 'a region one subscription could not read is not read for the target options' {
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
                if ($SubscriptionId -eq '11111111-2222-3333-4444-555555555555') { throw 'AuthorizationFailed' }
                & $script:catalogMock
            }
            $r = New-VmfTargetAdvice -AssessmentPath (Join-Path $script:sRun 'assessment.json') -WarningAction SilentlyContinue
            @($r.RegionsNotRead) | Should -Be @('centralus')
            $advice = Get-Content (Join-Path $script:sRun 'target-advice.json') -Raw | ConvertFrom-Json -Depth 30
            $advice.regions[0].read | Should -BeFalse -Because 'one subscription''s machines there got no options'
            $b = $advice.machines | Where-Object vmId -EQ $script:vmB
            $a = $advice.machines | Where-Object vmId -EQ $script:vmA
            @($b.options | Where-Object supported).Count | Should -Be 0
            (@($a.options | Where-Object { $_.option -eq 'v6' })[0]).supported | Should -BeTrue -Because 'A was read'
        }

        It 'the plan gives each machine a size from its own subscription''s catalog' {
            New-VmfTargetAdvice -AssessmentPath (Join-Path $script:sRun 'assessment.json') | Out-Null
            New-VmfPlan -AssessmentPath (Join-Path $script:sRun 'assessment.json') -OutPath "$($script:sRun)-migration" -TargetGeneration 'v6' | Out-Null
            $plan = Get-Content (Join-Path "$($script:sRun)-migration" 'plan.json') -Raw | ConvertFrom-Json -Depth 30
            ($plan.entries | Where-Object vmId -EQ $script:vmA).target.size | Should -Be 'Standard_D2s_v6'
            ($plan.entries | Where-Object vmId -EQ $script:vmB).target.size | Should -Not -Be 'Standard_D2s_v6'
            Should -Invoke -ModuleName VmMigrationFactory Get-VmfSkuCatalog -Times 0 -Exactly -ParameterFilter { -not $SubscriptionId }
            # The copy the service reads stays one per region, and keeps every
            # size any subscription there was offered.
            $snap = Get-Content (Join-Path "$($script:sRun)-migration" 'catalog' 'centralus.json') -Raw | ConvertFrom-Json -Depth 10
            @($snap.sizes | ForEach-Object { $_.name }) | Should -Contain 'Standard_D2s_v6'
            @($snap.sizes | Where-Object { $_.name -eq 'Standard_D2s_v5' }).Count | Should -Be 1 -Because 'a size two subscriptions are offered is kept once'
        }

        It 'the scan reads the catalog as the subscription of each machine' {
            $rows = foreach ($id in $script:vmA, $script:vmB) {
                [pscustomobject]@{ id = $id; name = 'app1'; resourceGroup = 'rg-app'; location = 'centralus'; zones = @()
                    sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'
                    imagePublisher = 'Canonical'; imageSku = '22_04-lts-gen2'; vmssId = ''
                    hibernationEnabled = $false; securityType = ''; dataDiskCount = 1; tags = $null; identityType = 'None'; identityPrincipalId = '' }
            }
            InModuleScope VmMigrationFactory -Parameters @{ rows = $rows; sa = $script:subA; sb = $script:subB } {
                param($rows, $sa, $sb)
                Mock Get-VmfFleetInventory { , @($rows) }
                Mock Get-VmfMachineImageNvme { @{ Nvme = $null; Note = $null } }
                Mock Get-VmfNicFacts { @{ Accelerated = @{}; ClusterHints = @{} } }
                Mock Get-VmfSqlIaaSAgentVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
                Mock Get-VmfAvdSessionHostIds { @{ Ids = @{}; PoolTypes = @{}; Verified = $true; Detail = 'mocked' } }
                Mock Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
                Mock Get-VmfManagedPlatformGroups { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
                Mock Get-VmfSqlVirtualMachines { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
                Mock Get-VmfDiskShareMap { @{ Disks = @{}; Types = @{}; Verified = $true; Detail = 'mocked' } }
                Mock Get-VmfResourceGroupOwners { @{ Groups = @{ "$sa/rg-app" = ''; "$sb/rg-app" = '' }; Verified = $true; Detail = 'mocked' } }
                $out = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ia3a-$([guid]::NewGuid().ToString('N').Substring(0,8))"
                try { Invoke-VmfAssessment -Scope @{ Subscriptions = @($sa, $sb) } -OutPath $out | Out-Null }
                finally { if (Test-Path $out) { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue } }
            }
            Should -Invoke -ModuleName VmMigrationFactory Get-VmfSkuCatalog -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq '00000000-0000-0000-0000-000000000000' }
            Should -Invoke -ModuleName VmMigrationFactory Get-VmfSkuCatalog -Times 1 -Exactly -ParameterFilter { $SubscriptionId -eq '11111111-2222-3333-4444-555555555555' }
            Should -Invoke -ModuleName VmMigrationFactory Get-VmfSkuCatalog -Times 0 -Exactly -ParameterFilter { -not $SubscriptionId }
        }
    }
}

Describe 'ID-ADDRESS-1 part 3: the tools find one resource of each kind, never the first of a prefix' {
    BeforeAll {
        . (Join-Path $script:repoRoot 'infra' 'Resolve-VmfRegistration.ps1')
        $script:twoFacades = @([pscustomobject]@{ name = 'vmf-facade-aaaa'; defaultHostName = 'a.example.com'; identity = @{ principalId = 'old' } },
                               [pscustomobject]@{ name = 'vmf-facade-b1-aaaa'; defaultHostName = 'b.example.com'; identity = @{ principalId = 'new' } })
    }

    It 'two names that start alike are refused, with both names and the parameter to give' {
        { Select-VmfOneByName -Items $script:twoFacades -Prefix 'vmf-facade' -What 'function apps' -NameParameter 'FacadeName' -ResourceGroup 'rg-vmf' -Use 'check' } |
            Should -Throw "*Resource group 'rg-vmf' holds 2 function apps whose names start 'vmf-facade': vmf-facade-aaaa, vmf-facade-b1-aaaa*does not guess which one to check*-FacadeName*"
    }

    It 'an exact name picks that one; one match is the answer; none is nothing' {
        (Select-VmfOneByName -Items $script:twoFacades -Exact 'vmf-facade-b1-aaaa' -Prefix 'vmf-facade' -What 'function apps' -NameParameter 'FacadeName' -ResourceGroup 'rg-vmf').identity.principalId | Should -Be 'new'
        (Select-VmfOneByName -Items @($script:twoFacades[0], [pscustomobject]@{ name = 'contoso-app' }) -Prefix 'vmf-facade' -What 'function apps' -NameParameter 'FacadeName' -ResourceGroup 'rg-vmf').name | Should -Be 'vmf-facade-aaaa'
        Select-VmfOneByName -Items @([pscustomobject]@{ name = 'contoso-app' }) -Prefix 'vmf-facade' -What 'function apps' -NameParameter 'FacadeName' -ResourceGroup 'rg-vmf' | Should -BeNullOrEmpty
        Select-VmfOneByName -Items $script:twoFacades -Exact 'vmf-facade-cccc' -Prefix 'vmf-facade' -What 'function apps' -NameParameter 'FacadeName' -ResourceGroup 'rg-vmf' | Should -BeNullOrEmpty -Because 'an exact name never falls back to the prefix'
        Select-VmfOneByName -Items @() -Prefix 'vmf-facade' -What 'function apps' -NameParameter 'FacadeName' -ResourceGroup 'rg-vmf' | Should -BeNullOrEmpty
    }

    It 'no tool or install script takes the first of a name-prefix match' {
        # The class, not the three instances: a Where-Object on "-like 'vmf...*'"
        # followed by "Select-Object -First 1" in one pipeline.
        $files = @(Get-ChildItem (Join-Path $script:repoRoot 'tools') -Filter '*.ps1') + @(Get-ChildItem (Join-Path $script:repoRoot 'infra') -Recurse -Filter '*.ps1')
        $hits = foreach ($f in $files) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            foreach ($pipe in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.PipelineAst] }, $true)) {
                $text = $pipe.Extent.Text
                # Case matters: resource names are lower case (vmf-facade, vmfstate);
                # 'VMF Assessment*' is a role name, not a resource name.
                if ($text -cmatch "-like\s+'vmf[a-z-]*\*'" -and $text -match 'Select-Object\s+-First\s+1') { "$($f.Name):$($pipe.Extent.StartLineNumber)" }
            }
        }
        @($hits) | Should -BeNullOrEmpty
    }

    It 'the dashboard publisher finds the facade through the same rule, and a listing that fails is said' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1')
        $code | Should -Match "Select-VmfOneByName -Items \`$facadeApps -Exact \`$FacadeName -Prefix 'vmf-facade' -What 'function apps' -NameParameter 'FacadeName'"
        # INSTALL-THROTTLE-RETRY-1: the listing is a step with no -AllowFailure,
        # so a failure stops the publish and names it.
        $code | Should -Match "\`$facadeJson = Invoke-VmfAzStep -Step `"list the function apps in '\`$ResourceGroup'`" -Command \{ az functionapp list"
    }

    It 'the grant script uses the same rule' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Grant-VmfAccess.ps1')
        ([regex]::Matches($code, 'Select-VmfOneByName ')).Count | Should -Be 2
    }

    Context 'the health check, run with a stand-in for az' {
        BeforeAll {
            $script:healthPath = Join-Path $script:repoRoot 'tools' 'Test-VmfHealth.ps1'
            # What each listing gives back; a test changes one of them. Global: the
            # stand-in runs inside the health script, where $script: names its scope.
            $global:Ia3Listed = @{}
            function Global:Ia3HealthAz {
                $line = $args -join ' '
                $global:LASTEXITCODE = 0
                if ($line -like 'account show*') { return '{"user":{"name":"operator@example.com"},"name":"contoso-sub","id":"00000000-0000-0000-0000-000000000000"}' }
                foreach ($k in $global:Ia3Listed.Keys) { if ($line -like "$k*") { return ($global:Ia3Listed[$k] | ConvertTo-Json -Depth 5 -AsArray) } }
                '[]'
            }
        }
        AfterAll { Remove-Item 'function:\Ia3HealthAz', 'variable:\Ia3Listed' -ErrorAction SilentlyContinue }
        BeforeEach {
            $global:Ia3Listed = @{
                'functionapp list' = @([pscustomobject]@{ name = 'vmf-facade-aaaa'; defaultHostName = 'a.example.com' })
                'webapp list'      = @([pscustomobject]@{ name = 'vmf-dash-aaaa'; defaultHostName = 'd.example.com' })
                'identity list'    = @([pscustomobject]@{ name = 'vmf-engine-mi-aaaa'; principalId = 'p1' })
                'storage account list' = @()
            }
            Set-Alias -Name az -Value Ia3HealthAz -Scope Global
            # The facade block asks the pages over HTTP; nothing here may.
            Mock Invoke-RestMethod { throw 'no network in a unit test' }
            Mock Invoke-WebRequest { throw 'no network in a unit test' }
            $script:healthRun = { param([hashtable]$Arguments) & $script:healthPath @Arguments 6>&1 | Out-String -Width 4000 }
        }
        AfterEach { Remove-Item 'alias:\az' -Force -ErrorAction SilentlyContinue }

        It 'two facades whose names start alike are a PROBLEM that names both, never the first one checked' {
            $global:Ia3Listed['functionapp list'] = $script:twoFacades
            $said = & $script:healthRun @{ ResourceGroup = 'rg-vmf' }
            $said | Should -Match "PROBLEM.*holds 2 function apps whose names start 'vmf-facade': vmf-facade-aaaa, vmf-facade-b1-aaaa"
            $said | Should -Match 'Give the name of the correct one with -FacadeName'
            $said | Should -Not -Match 'service vmf-facade-aaaa'
        }

        It 'the exact name checks that one' {
            $global:Ia3Listed['functionapp list'] = $script:twoFacades
            $said = & $script:healthRun @{ ResourceGroup = 'rg-vmf'; FacadeName = 'vmf-facade-b1-aaaa' }
            $said | Should -Match 'OK\s+service vmf-facade-b1-aaaa, dashboard vmf-dash-aaaa'
        }

        It 'two dashboards, engine identities or run stores are refused the same way' {
            $global:Ia3Listed['webapp list'] = @([pscustomobject]@{ name = 'vmf-dash-aaaa' }, [pscustomobject]@{ name = 'vmf-dash-bbbb' })
            $global:Ia3Listed['identity list'] = @([pscustomobject]@{ name = 'vmf-engine-mi-aaaa'; principalId = 'p1' }, [pscustomobject]@{ name = 'vmf-engine-mi-bbbb'; principalId = 'p2' })
            $global:Ia3Listed['storage account list'] = @([pscustomobject]@{ name = 'vmfstateaaaa'; id = '/x/a' }, [pscustomobject]@{ name = 'vmfstatebbbb'; id = '/x/b' })
            $said = & $script:healthRun @{ ResourceGroup = 'rg-vmf' }
            $said | Should -Match 'vmf-dash-aaaa, vmf-dash-bbbb.*-DashboardName'
            $said | Should -Match 'vmf-engine-mi-aaaa, vmf-engine-mi-bbbb.*-EngineIdentityName'
            $said | Should -Match 'vmfstateaaaa, vmfstatebbbb.*-StorageAccountName'
        }
    }
}
