#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# NIC-JOIN-1: writing a network interface is also a JOIN of everything it links
# to, and Azure checks that on the linked resource.
#
# MEASURED 2026-09-27 on the first end-to-end run of ADVISOR-1. Turning
# accelerated networking on for a machine going to v5 was refused inside the
# stopped window (redacted):
#
#   has permission to perform action 'Microsoft.Network/networkInterfaces/write'
#   on scope '.../networkInterfaces/<nic>'; however, it does not have permission
#   to perform action(s) 'Microsoft.Network/virtualNetworks/subnets/join/action'
#   on the linked scope(s) '.../virtualNetworks/<vnet>/subnets/<subnet>'
#
# and the machine was rolled back. Every move turns accelerated networking on
# for a machine that has it off, unless the plan says otherwise - so every such
# machine would have failed the same way.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'nj'

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000'
    $script:subnet = "$script:sub/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet/subnets/app"
    $script:nsg = "$script:sub/resourceGroups/rg-net/providers/Microsoft.Network/networkSecurityGroups/app-nsg"
    $script:nicId = "$script:sub/resourceGroups/rg-app/providers/Microsoft.Network/networkInterfaces/vm1-nic"
    $script:map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json

    # The interface as ARM returns it (the Az object is covered separately).
    $script:armNic = [pscustomobject]@{ id = $script:nicId; properties = [pscustomobject]@{
        networkSecurityGroup = [pscustomobject]@{ id = $script:nsg }
        ipConfigurations = @([pscustomobject]@{ properties = [pscustomobject]@{
            subnet = [pscustomobject]@{ id = $script:subnet }
            loadBalancerBackendAddressPools = @([pscustomobject]@{ id = "$script:sub/resourceGroups/rg-net/providers/Microsoft.Network/loadBalancers/lb/backendAddressPools/pool" }) } }) } }

    function Script:Links($nic) { InModuleScope VmMigrationFactory -Parameters @{ n = $nic } { Get-VmfNicLinkedActions -Nic $n } }
    function Script:Gate([string]$Policy, $Nics, [hashtable]$Granted) {
        $rp = Join-Path $script:temp "nj-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'nj' | Out-Null }
        $script:granted = $Granted
        Mock -ModuleName VmMigrationFactory Get-VmfNetworkInterfaceById { $script:armNic }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
            @([pscustomobject]@{ actions = @($script:granted[$Scope]); notActions = @() })
        }
        $plan = [pscustomobject]@{ target = [pscustomobject]@{ size = 'Standard_D2s_v5'; controller = 'SCSI' }
            policy = $(if ($Policy) { [pscustomobject]@{ acceleratedNetworking = $Policy } } else { [pscustomobject]@{} }) }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; p = $plan; n = $Nics } {
            Test-VmfNicLinkedPermissions -Context @{ RunPath = $rp; VmId = '/vm/1' } -PlanEntry $p -CapturedNics $n
        }
    }
}

AfterAll { Remove-VmfTestTemp }

Describe 'NIC-JOIN-1: the role carries the joins' {

    It 'the interface write lists the subnet join Azure demanded, and the rest of Microsoft''s set' {
        $op = @($script:map.operations | Where-Object cmdlet -eq 'Set-AzNetworkInterface')[0]
        foreach ($a in 'Microsoft.Network/networkInterfaces/write', 'Microsoft.Network/virtualNetworks/subnets/join/action',
                       'Microsoft.Network/networkSecurityGroups/join/action', 'Microsoft.Network/publicIPAddresses/join/action',
                       'Microsoft.Network/loadBalancers/backendAddressPools/join/action') {
            @($op.actions) | Should -Contain $a
        }
        $op.why | Should -Match 'LinkedAuthorizationFailed'
    }

    It 'every join the check asks for is one the role grants - the check cannot demand what the role lacks' {
        $granted = @($script:map.operations | Where-Object role -eq 'execute' | ForEach-Object { $_.actions })
        $asked = InModuleScope VmMigrationFactory { @($script:VmfNicLinkJoins.Values) }
        foreach ($a in $asked) { $granted | Should -Contain $a }
    }
}

Describe 'NIC-JOIN-1: what an interface links to' {

    It 'reads the subnet, the network security group and a load balancer pool from the ARM shape' {
        $l = Script:Links $script:armNic
        ($l | Where-Object Scope -eq $script:subnet).Action | Should -Be 'Microsoft.Network/virtualNetworks/subnets/join/action'
        ($l | Where-Object Scope -eq $script:nsg).Action | Should -Be 'Microsoft.Network/networkSecurityGroups/join/action'
        @($l | Where-Object Kind -eq 'lbBackendAddressPool').Count | Should -Be 1
    }

    It 'and from the Az object shape, whose names differ in case' {
        $az = [pscustomobject]@{ Id = $script:nicId; NetworkSecurityGroup = $null
            IpConfigurations = @([pscustomobject]@{ Subnet = [pscustomobject]@{ Id = $script:subnet }; PublicIpAddress = [pscustomobject]@{ Id = "$script:sub/pip" } }) }
        $l = Script:Links $az
        @($l.Kind) | Should -Be @('publicIPAddress', 'subnet')
    }

    It 'nothing read is nothing asked' {
        @(Script:Links $null).Count | Should -Be 0
    }
}

Describe 'NIC-JOIN-1: the check before anything is touched' {

    It 'THE DEFECT: an interface the move will turn on, whose subnet this identity cannot join, stops at Checking, naming both' {
        $r = Script:Gate -Policy 'ensureOn' -Nics @(@{ id = $script:nicId; primary = $true; acceleratedNetworking = $false }) -Granted @{
            $script:nsg = @('Microsoft.Network/networkSecurityGroups/join/action'); $script:subnet = @('Microsoft.Network/virtualNetworks/read') }
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'permissionMissingNetwork'
        $r.Detail | Should -Match ([regex]::Escape('Microsoft.Network/virtualNetworks/subnets/join/action'))
        $r.Detail | Should -Match ([regex]::Escape($script:subnet))
        $r.Detail | Should -Match 'stopped before touching the machine'
    }

    It 'a wildcard grant on the network covers it' {
        $r = Script:Gate -Policy 'ensureOn' -Nics @(@{ id = $script:nicId; primary = $true; acceleratedNetworking = $false }) -Granted @{
            $script:nsg = @('Microsoft.Network/*'); $script:subnet = @('Microsoft.Network/*')
            "$script:sub/resourceGroups/rg-net/providers/Microsoft.Network/loadBalancers/lb/backendAddressPools/pool" = @('Microsoft.Network/*') }
        $r | Should -BeNullOrEmpty
    }

    It 'an interface the move does not write is not asked about at all' {
        Script:Gate -Policy 'ensureOn' -Nics @(@{ id = $script:nicId; primary = $true; acceleratedNetworking = $true }) -Granted @{} |
            Should -BeNullOrEmpty -Because 'accelerated networking is already on, so nothing is written'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfNetworkInterfaceById -Times 0 -Exactly
    }

    It 'preserve writes nothing and asks nothing' {
        Script:Gate -Policy 'preserve' -Nics @(@{ id = $script:nicId; primary = $true; acceleratedNetworking = $false }) -Granted @{} |
            Should -BeNullOrEmpty
    }

    It 'Checking calls it, after the capture and before anything changes' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $pre = [regex]::Match($code, '(?s)function Invoke-VmfStepPrecheck \{.*?\nfunction ').Value
        $pre | Should -Match 'Test-VmfNicLinkedPermissions -Context \$Context -PlanEntry \$plan -CapturedNics \$capturedConfig\.nics'
        $pre.IndexOf('Save-VmfCapturedFacts') | Should -BeLessThan $pre.IndexOf('Test-VmfNicLinkedPermissions')
    }
}
