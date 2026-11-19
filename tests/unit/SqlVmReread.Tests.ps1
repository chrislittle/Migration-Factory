#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SQLVM-REREAD-1: Checking read the SQL virtual machine resource again.
#
# A rebuild (Path B) deleted the machine's definition, and Azure deleted the
# SQL virtual machine resource (Microsoft.SqlVirtualMachine/sqlVirtualMachines)
# with it. SQLVM-REREAD-1 read it again at Checking, for every rebuild.
#
# REBUILD-REMOVE-ACCEPT-1 removed the read at Checking with the rebuild gate.
# REBUILD-REMOVE-ROLE-1 removed the read of one machine
# (Get-VmfVmSqlVirtualMachine), which had no caller. The scan still lists the
# SQL virtual machines of each subscription (DETECT-PATTERNS-1: a member of an
# availability group is refused), so the role keeps the read. What stays here:
# that read stays in the role, and the contracts still hold an earlier record.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:temp = New-VmfTestTemp -Prefix 'sqr'
    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1'
    function Global:SqRun {
        $rp = Join-Path $script:temp "r-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'sqr' | Out-Null }
        $rp
    }
}

AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\SqRun' -ErrorAction SilentlyContinue
}

Describe 'SQLVM-REREAD-1: the scan''s read stays' {
    It 'the read of one machine is gone, and the scan''s read of each subscription stays' {
        InModuleScope VmMigrationFactory {
            Get-Command Get-VmfVmSqlVirtualMachine -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            Get-Command Get-VmfSqlVirtualMachines -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        }
    }

    It 'the role holds the read: it is in the scan''s part of the permission map' {
        $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        @($map.operations | Where-Object { $_.role -eq 'assess' } | ForEach-Object { $_.actions }) | Should -Contain 'Microsoft.SqlVirtualMachine/sqlVirtualMachines/read'
    }
}
Describe 'SQLVM-REREAD-1: the contract' {
    It 'REBUILD-REMOVE-ACCEPT-1: the stop for a read that failed is gone with the read' {
        InModuleScope VmMigrationFactory { Get-VmfStopGuidance -Code 'sqlVirtualMachineNotRead' | Should -BeNullOrEmpty }
    }

    It 'OLD-VERSION-READERS-REMOVE-1: neither the machine state nor the plan entry holds the SQL virtual machine resource for a rebuild' {
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $s.properties.captured.properties.PSObject.Properties.Name | Should -Not -Contain 'sqlVirtualMachine'
        $p = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $p.properties.decisions.items.properties.PSObject.Properties.Name | Should -Not -Contain 'sqlVirtualMachine'
    }
    It 'the migration note names both versions' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match 'vm-state v34 -> v35'
        $notes | Should -Match 'plan-entry v24 -> v25'
    }
}
