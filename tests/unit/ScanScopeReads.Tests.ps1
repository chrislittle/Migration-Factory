#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# SCAN-SCOPE-READS-1: an assessment reads nothing outside the scope the person
# chose (ruled 2026-11-14).
#
# Two reads went wider, to every subscription the product's identity can see:
#   - the Azure Virtual Desktop check listed the identity's subscriptions
#     (GET /subscriptions) and read the host pools in all of them;
#   - the AKS and Databricks check sent a Resource Graph query with no
#     subscription and no management group, which Resource Graph reads across
#     every subscription the identity can see.
# Every other assessment read already sends the scope (SCOPE-1). These tests
# hold both reads to it, and hold the whole scan away from GET /subscriptions.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # One whole scan of one machine in subscription 00000000-0000-0000-0000-000000000000. Every read is mocked
    # EXCEPT the AVD and the AKS/Databricks reads, which run for real against
    # a recording Invoke-AzRestMethod and Invoke-VmfResourceGraphQuery.
    # Gives back the ARM paths and the Resource Graph bodies the scan sent.
    function Global:SsrScan([hashtable]$Scope, [string[]]$MgSubs = @()) {
        $row = [pscustomobject]@{
            id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1'; name = 'vm1'
            resourceGroup = 'rg-app'; location = 'centralus'; zones = $null
            sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'; osName = 'ubuntu'; osVersionRunning = '22.04'
            imagePublisher = 'Canonical'; imageOffer = '0001-com-ubuntu-server-jammy'; imageSku = '22_04-lts-gen2'; imageId = ''
            communityGalleryImageId = ''; sharedGalleryImageId = ''; planPublisher = ''; planProduct = ''
            vmssId = ''; hibernationEnabled = $false; securityType = ''; dataDiskCount = 0; dataDisks = @()
            tags = $null; identityType = 'None'; identityPrincipalId = ''; adeOsDiskEnabled = ''; licenseType = ''
            osDiskManagedId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1-os'
        }
        $params = @{ row = $row; scope = $Scope; mgSubs = $MgSubs }
        InModuleScope VmMigrationFactory -Parameters $params {
            param($row, $scope, $mgSubs)
            $script:ssrPaths = [System.Collections.Generic.List[string]]::new()
            $script:ssrBodies = [System.Collections.Generic.List[object]]::new()
            $script:ssrMgSubs = $mgSubs
            Mock Get-VmfFleetInventory { , @($row) }
            Mock Get-VmfSkuCatalog { , @() }
            Mock Get-VmfMachineImageNvme { @{ Nvme = $null; Note = $null } }
            Mock Get-VmfNicFacts { @{ Accelerated = @{}; ClusterHints = @{} } }
            Mock Get-VmfSqlIaaSAgentVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSqlVirtualMachines { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfDiskShareMap { @{ Disks = @{}; Types = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfResourceGroupOwners { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Invoke-AzRestMethod {
                $script:ssrPaths.Add([string]$(if ($Path) { $Path } else { $Uri }))
                if ($Path -match '^/subscriptions\?') {
                    [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(@{ subscriptionId = '00000000-0000-0000-0000-000000000000' }, @{ subscriptionId = '00000000-1111-1111-1111-111111111111' }) } | ConvertTo-Json -Depth 5) }
                }
                else { [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NoRegisteredProviderFound"}}' } }
            }
            Mock Invoke-VmfResourceGraphQuery {
                $script:ssrBodies.Add($Body)
                if ([string]$Body.query -match 'microsoft\.resources/subscriptions''') {
                    [pscustomobject]@{ data = @($script:ssrMgSubs | ForEach-Object { [pscustomobject]@{ subscriptionId = $_ } }) }
                }
                else { [pscustomobject]@{ data = @() } }
            }
            $out = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ssr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            try {
                Invoke-VmfAssessment -Scope $scope -OutPath $out | Out-Null
                [pscustomobject]@{ Paths = @($script:ssrPaths); Bodies = @($script:ssrBodies) }
            }
            finally { if (Test-Path $out) { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue } }
        }
    }
}

AfterAll {
    Remove-Item function:SsrScan -ErrorAction SilentlyContinue
}

Describe 'SCAN-SCOPE-READS-1: the AKS and Databricks read sends only the scope' {
    It 'the Resource Graph query carries the subscriptions it was given, and nothing tenant-wide' {
        InModuleScope VmMigrationFactory {
            $script:mgBodies = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-VmfResourceGraphQuery { $script:mgBodies.Add($Body); [pscustomobject]@{ data = @() } }
            $r = Get-VmfManagedPlatformGroups -Subscriptions @('00000000-0000-0000-0000-000000000000', '11111111-2222-3333-4444-555555555555')
            $r.Verified | Should -BeTrue
            $script:mgBodies.Count | Should -Be 1
            @($script:mgBodies[0].subscriptions) | Should -Be @('00000000-0000-0000-0000-000000000000', '11111111-2222-3333-4444-555555555555')
            $script:mgBodies[0].ContainsKey('managementGroups') | Should -BeFalse
        }
    }

    It 'every page of the query carries the subscriptions, not only the first' {
        InModuleScope VmMigrationFactory {
            $script:mgBodies = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-VmfResourceGraphQuery {
                $script:mgBodies.Add($Body)
                if ($script:mgBodies.Count -eq 1) { [pscustomobject]@{ data = @(); '$skipToken' = 'more' } }
                else { [pscustomobject]@{ data = @() } }
            }
            Get-VmfManagedPlatformGroups -Subscriptions @('00000000-0000-0000-0000-000000000000') | Out-Null
            $script:mgBodies.Count | Should -Be 2
            foreach ($b in $script:mgBodies) { @($b.subscriptions) | Should -Be @('00000000-0000-0000-0000-000000000000') }
        }
    }

    It 'the record says the groups were read in the scanned subscriptions, not in every visible one' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfResourceGraphQuery { [pscustomobject]@{ data = @() } }
            $r = Get-VmfManagedPlatformGroups -Subscriptions @('00000000-0000-0000-0000-000000000000')
            $r.Detail | Should -Not -Match 'visible to this identity'
            $r.Detail | Should -Match '1 subscription'
        }
    }
}

Describe 'SCAN-SCOPE-READS-1: the AVD read lists host pools only in the scope' {
    It 'with subscriptions as the scope: host pools in those subscriptions only, and no GET /subscriptions' {
        InModuleScope VmMigrationFactory {
            $script:avdPaths = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-AzRestMethod {
                $script:avdPaths.Add([string]$Path)
                if ($Path -match '^/subscriptions\?') {
                    [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(@{ subscriptionId = '00000000-0000-0000-0000-000000000000' }, @{ subscriptionId = '00000000-1111-1111-1111-111111111111' }) } | ConvertTo-Json -Depth 5) }
                }
                else { [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NoRegisteredProviderFound"}}' } }
            }
            $r = Get-VmfAvdSessionHostIds -Subscriptions @('00000000-0000-0000-0000-000000000000', '11111111-2222-3333-4444-555555555555')
            $r.Verified | Should -BeTrue
            @($script:avdPaths | Where-Object { $_ -match '^/subscriptions\?' }).Count | Should -Be 0
            @($script:avdPaths | Where-Object { $_ -match '00000000-1111-1111-1111-111111111111' }).Count | Should -Be 0
            @($script:avdPaths | Where-Object { $_ -match '^/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.DesktopVirtualization/hostPools' }).Count | Should -Be 1
            @($script:avdPaths | Where-Object { $_ -match '^/subscriptions/11111111-2222-3333-4444-555555555555/providers/Microsoft.DesktopVirtualization/hostPools' }).Count | Should -Be 1
            # The record still says how many subscriptions were checked.
            $r.Detail | Should -Match '2 subscription'
        }
    }

    It 'with a management group as the scope: the subscriptions under it come from Resource Graph with that group, and only they are read' {
        InModuleScope VmMigrationFactory {
            $script:avdPaths = [System.Collections.Generic.List[string]]::new()
            $script:avdBodies = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-AzRestMethod {
                $script:avdPaths.Add([string]$Path)
                [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NoRegisteredProviderFound"}}' }
            }
            Mock Invoke-VmfResourceGraphQuery {
                $script:avdBodies.Add($Body)
                [pscustomobject]@{ data = @([pscustomobject]@{ subscriptionId = '11111111-2222-3333-4444-555555555555' }, [pscustomobject]@{ subscriptionId = '00000000-0000-0000-0000-000000000000' }) }
            }
            $r = Get-VmfAvdSessionHostIds -Subscriptions @('00000000-0000-0000-0000-000000000000') -ManagementGroup 'mg-contoso'
            $r.Verified | Should -BeTrue
            $script:avdBodies.Count | Should -Be 1
            @($script:avdBodies[0].managementGroups) | Should -Be @('mg-contoso')
            $script:avdBodies[0].ContainsKey('subscriptions') | Should -BeFalse
            @($script:avdPaths | Where-Object { $_ -match '^/subscriptions\?' }).Count | Should -Be 0
            @($script:avdPaths | Where-Object { $_ -match '/hostPools\?' }).Count | Should -Be 2
            @($script:avdPaths | Where-Object { $_ -match '^/subscriptions/11111111-2222-3333-4444-555555555555/providers/Microsoft.DesktopVirtualization/hostPools' }).Count | Should -Be 1
            $r.Detail | Should -Match '2 subscription'
        }
    }

    It 'a host pool in the scope is still found when its session hosts are in another subscription of the scope' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-AzRestMethod {
                if ($Path -match '^/subscriptions/11111111-2222-3333-4444-555555555555/providers/Microsoft.DesktopVirtualization/hostPools\?') {
                    [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(@{ id = '/subscriptions/11111111-2222-3333-4444-555555555555/rg/hp1'; name = 'hp1' }) } | ConvertTo-Json -Depth 5) }
                }
                elseif ($Path -match 'hp1/sessionHosts') {
                    [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @(@{ name = 'sh1'; properties = @{ resourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/rg/providers/Microsoft.Compute/virtualMachines/AVD-1' } }) } | ConvertTo-Json -Depth 5) }
                }
                else { [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NoRegisteredProviderFound"}}' } }
            }
            $r = Get-VmfAvdSessionHostIds -Subscriptions @('00000000-0000-0000-0000-000000000000', '11111111-2222-3333-4444-555555555555')
            $r.Verified | Should -BeTrue
            $r.Ids.ContainsKey('/subscriptions/00000000-0000-0000-0000-000000000000/rg/providers/microsoft.compute/virtualmachines/avd-1') | Should -BeTrue
        }
    }

    It 'a management group whose subscriptions cannot be read is NOT verified - the scan refuses' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NoRegisteredProviderFound"}}' } }
            Mock Invoke-VmfResourceGraphQuery { throw 'Resource Graph query failed: HTTP 403 - AuthorizationFailed' }
            $r = Get-VmfAvdSessionHostIds -Subscriptions @('00000000-0000-0000-0000-000000000000') -ManagementGroup 'mg-contoso'
            $r.Verified | Should -BeFalse
            $r.Detail | Should -Match ([regex]::Escape('the scan cannot list the subscriptions under management group mg-contoso: '))
        }
    }
}

Describe 'SCAN-SCOPE-READS-1: no read of the scan goes outside the scope' {
    It 'a scan of chosen subscriptions never calls GET /subscriptions, and every Resource Graph query carries a scope' {
        $sent = SsrScan -Scope @{ Subscriptions = @('00000000-0000-0000-0000-000000000000') }
        @($sent.Paths | Where-Object { $_ -match '^/subscriptions\?' }).Count | Should -Be 0
        @($sent.Paths | Where-Object { $_ -match '00000000-1111-1111-1111-111111111111' }).Count | Should -Be 0
        @($sent.Paths | Where-Object { $_ -match '/hostPools\?' }).Count | Should -Be 1
        $sent.Bodies.Count | Should -BeGreaterThan 0 -Because 'the AKS and Databricks read ran'
        foreach ($b in $sent.Bodies) {
            ($b.ContainsKey('subscriptions') -or $b.ContainsKey('managementGroups')) | Should -BeTrue -Because 'a query with no scope reads every subscription the identity can see'
        }
        $managed = @($sent.Bodies | Where-Object { [string]$_.query -match 'managedclusters' })
        $managed.Count | Should -Be 1
        @($managed[0].subscriptions) | Should -Be @('00000000-0000-0000-0000-000000000000')
    }

    It 'a scan of chosen subscriptions reads the host pools of a chosen subscription that holds no machine' {
        # The headline case: the host pools sit in a management subscription
        # with no machine in it. Only the scope names it; the machines do not.
        $sent = SsrScan -Scope @{ Subscriptions = @('00000000-0000-0000-0000-000000000000', '11111111-2222-3333-4444-555555555555') }
        @($sent.Paths | Where-Object { $_ -match '^/subscriptions/11111111-2222-3333-4444-555555555555/providers/Microsoft.DesktopVirtualization/hostPools' }).Count | Should -Be 1
        @($sent.Paths | Where-Object { $_ -match '/hostPools\?' }).Count | Should -Be 2
        @($sent.Paths | Where-Object { $_ -match '^/subscriptions\?' }).Count | Should -Be 0
    }

    It 'a scan of a management group reads the host pools in the subscriptions under it, and nowhere else' {
        $sent = SsrScan -Scope @{ ManagementGroup = 'mg-contoso' } -MgSubs @('00000000-0000-0000-0000-000000000000', '11111111-2222-3333-4444-555555555555')
        @($sent.Paths | Where-Object { $_ -match '^/subscriptions\?' }).Count | Should -Be 0
        @($sent.Paths | Where-Object { $_ -match '/hostPools\?' }).Count | Should -Be 2
        @($sent.Paths | Where-Object { $_ -match '^/subscriptions/11111111-2222-3333-4444-555555555555/providers/Microsoft.DesktopVirtualization/hostPools' }).Count | Should -Be 1
        foreach ($b in $sent.Bodies) {
            ($b.ContainsKey('subscriptions') -or $b.ContainsKey('managementGroups')) | Should -BeTrue
        }
        $containers = @($sent.Bodies | Where-Object { [string]$_.query -match 'microsoft\.resources/subscriptions''' })
        $containers.Count | Should -Be 1
        @($containers[0].managementGroups) | Should -Be @('mg-contoso')
    }

    It 'the manual tells the person to include the subscription of the host pools, and says why' {
        $manual = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'use' 'assess.md') -Raw
        $manual | Should -Match ([regex]::Escape('Include the subscription that holds your Azure Virtual Desktop host pools in the scan.'))
        $manual | Should -Match ([regex]::Escape('The scan reads host pools only in the place that you choose.'))
        $manual | Should -Match ([regex]::Escape('A host pool can be in a different subscription from its session hosts.'))
    }

    It 'SCAN-RG-SCOPE-WORDS-1: the manual says the checks read the whole subscription of chosen resource groups, and no longer says otherwise' {
        $sentence = 'These checks read the whole subscription that holds the groups:'
        $manual = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'use' 'assess.md') -Raw
        $manual | Should -Match ([regex]::Escape($sentence))
        $manual | Should -Match ([regex]::Escape('The assessment records only the machines in the groups that you tick.'))
        $manual | Should -Not -Match 'nothing else in the subscription'
    }

    It 'the scan step shows no scope hint: both sentences are in the manual only' {
        $wizard = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.js')
        $wizard | Should -Not -Match 'scopeRgChecksHint|scopeAvdHint'
        $wizard | Should -Not -Match 'read the whole subscription'
        $wizard | Should -Not -Match 'Azure Virtual Desktop host pools'
    }

    It 'a scan of resource groups asks Resource Graph only for the machines in those groups' {
        InModuleScope VmMigrationFactory {
            $script:invBodies = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-VmfResourceGraphQuery { $script:invBodies.Add($Body); [pscustomobject]@{ data = @() } }
            Get-VmfFleetInventory -Subscriptions @('00000000-0000-0000-0000-000000000000') -ResourceGroups @('rg-app', 'RG-Web') | Out-Null
            $script:invBodies.Count | Should -Be 1
            [string]$script:invBodies[0].query | Should -Match ([regex]::Escape("| where resourceGroup in~ ('rg-app', 'RG-Web')"))
            @($script:invBodies[0].subscriptions) | Should -Be @('00000000-0000-0000-0000-000000000000')
        }
    }

    It 'a resource group name cannot end the list in the query: a quote in it is removed' {
        InModuleScope VmMigrationFactory {
            $script:invBodies = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-VmfResourceGraphQuery { $script:invBodies.Add($Body); [pscustomobject]@{ data = @() } }
            Get-VmfFleetInventory -Subscriptions @('00000000-0000-0000-0000-000000000000') -ResourceGroups @("rg') or true or ('x") | Out-Null
            [string]$script:invBodies[0].query | Should -Match ([regex]::Escape("| where resourceGroup in~ ('rg) or true or (x')"))
        }
    }

    It 'a backslash in a resource group name or a tag cannot escape the closing quote: it is removed' {
        InModuleScope VmMigrationFactory {
            $script:invBodies = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-VmfResourceGraphQuery { $script:invBodies.Add($Body); [pscustomobject]@{ data = @() } }
            $bs = [string][char]92
            Get-VmfFleetInventory -Subscriptions @('00000000-0000-0000-0000-000000000000') -ResourceGroups @("rg-a$bs") -TagFilter @{ key = "env$bs"; value = "prod$bs" } | Out-Null
            $q = [string]$script:invBodies[0].query
            $q | Should -Match ([regex]::Escape("| where resourceGroup in~ ('rg-a')"))
            $q | Should -Match ([regex]::Escape("tostring(tags['env']) =~ 'prod'"))
            $q.Contains($bs) | Should -BeFalse
        }
    }

    It 'a scan with no resource group filter asks for every machine in the scope, with no group filter' {
        InModuleScope VmMigrationFactory {
            $script:invBodies = [System.Collections.Generic.List[object]]::new()
            Mock Invoke-VmfResourceGraphQuery { $script:invBodies.Add($Body); [pscustomobject]@{ data = @() } }
            Get-VmfFleetInventory -Subscriptions @('00000000-0000-0000-0000-000000000000') | Out-Null
            [string]$script:invBodies[0].query | Should -Not -Match 'resourceGroup in~'
        }
    }

    It 'the resource groups sentence in the manual names every read that covers the whole subscription, network interfaces too' {
        $manual = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'use' 'assess.md') -Raw
        foreach ($read in @('Network interfaces', 'Azure Virtual Desktop', 'AKS', 'Azure Databricks', 'SAP', 'SQL Server', 'Shared disks')) {
            $manual | Should -Match ('(?m)^     - ' + [regex]::Escape($read) + '\r?$')
        }
    }

    It 'no code in the module lists the identity''s subscriptions, and the function that did is gone' {
        $files = Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Recurse -Filter '*.ps1'
        $hits = @(foreach ($f in $files) {
                if ((Get-VmfCodeOnly -Path $f.FullName) -match '/subscriptions\?api-version') { $f.Name }
            })
        $hits | Should -BeNullOrEmpty
        InModuleScope VmMigrationFactory { Get-Command Get-VmfVisibleSubscriptionIds -ErrorAction SilentlyContinue } | Should -BeNullOrEmpty
    }
}
