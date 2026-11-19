#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REBUILD-REMOVE-ROLE-1: the role, the Azure calls and the scan read that only
# the rebuild around the same disks needed are gone.
#
# It was decided on 2026-11-07 to remove the rebuild (Path B). The earlier
# parts of that removal took away every way to start one: no plan gives it, no
# acceptance accepts it, the state machine has no Path B step, and no restore
# rebuilds. What was left:
#
#   - the VMF Migration role still held Microsoft.Compute/virtualMachines/delete
#     (Remove-AzVM, the deletion of the machine's definition) and the New-AzVM
#     create of a machine around its own disks;
#   - the azureops functions that made those calls, and the engine helpers that
#     ran after a rebuild, had no caller;
#   - the scan still listed each machine's data collection rule associations,
#     which only the acceptance of a rebuild showed, and both roles held
#     Microsoft.Insights/dataCollectionRuleAssociations/read for it.
#
# THE RULE NOW. The role holds no right that no remaining code path uses. A
# right that a remaining path DOES use stays, and says why:
#
#   - Microsoft.Network/networkInterfaces/join/action stays, on the resize.
#     Microsoft names it "Attach a network interface to a virtual machine",
#     and a resize with Update-AzVM sends the whole definition, network
#     interfaces included: Microsoft Q&A 596739 shows a PowerShell resize
#     refused with LinkedAuthorizationFailed for exactly this action on the
#     interface. This product measured the same class on Update-AzVM for
#     userAssignedIdentities/assign/action (UAMI-ASSIGN-1).
#   - Microsoft.Features/providers/features/read stays: the Preview reads it
#     (TEMP-DISK-PREVIEW-1, TEMP-DISK-PREVIEW-ROLE-1).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:mapPath = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json'
    $script:map = Get-Content $script:mapPath -Raw | ConvertFrom-Json -Depth 20
    $script:schemaPath = Join-Path $script:repoRoot 'schemas' 'assessment.schema.json'
    $script:moduleRoot = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
    $script:allActions = @($script:map.operations | ForEach-Object { @($_.actions) }) | Sort-Object -Unique
    $script:executeActions = @($script:map.operations | Where-Object { $_.role -in 'assess', 'execute' } | ForEach-Object { @($_.actions) }) | Sort-Object -Unique

    # Every command name the module's code calls (the parser, so a comment that
    # still names a removed call does not count).
    $script:moduleCommands = @(
        Get-ChildItem $script:moduleRoot -Filter *.ps1 -Recurse | ForEach-Object {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
            $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() }
        }
    ) | Where-Object { $_ } | Sort-Object -Unique

    function Global:RrrRecord {
        InModuleScope VmMigrationFactory {
            $vm = [pscustomobject]@{ id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1'
                name = 'vm1'; resourceGroup = 'rg-app'; subscriptionId = '00000000-0000-0000-0000-000000000000'; location = 'centralus'; sku = 'Standard_D2s_v4'
                osType = 'Windows'; hyperVGeneration = 'V2'; tags = $null; powerState = 'PowerState/running' }
            Get-VmfAssessmentRecord -Vm $vm -SkuEntry $null -SqlVms @{}
        }
    }
}

AfterAll {
    foreach ($fn in 'RrrRecord') { Remove-Item "function:\$fn" -ErrorAction SilentlyContinue }
}

Describe 'REBUILD-REMOVE-ROLE-1: the role holds no right that only the rebuild used' {
    It 'no operation in the map deletes a virtual machine, and neither role holds the action' {
        $script:allActions | Should -Not -Contain 'Microsoft.Compute/virtualMachines/delete'
        @($script:map.operations.cmdlet) | Should -Not -Contain 'Remove-AzVM'
    }

    It 'no operation in the map creates a virtual machine' {
        @($script:map.operations.cmdlet) | Should -Not -Contain 'New-AzVM'
        foreach ($inMemory in 'New-AzVMConfig', 'Set-AzVMOSDisk', 'Set-AzVMBootDiagnostic', 'Set-AzVMSecurityProfile', 'Set-AzVmUefi', 'Add-AzVMNetworkInterface') {
            @($script:map.operations.cmdlet) | Should -Not -Contain $inMemory -Because "$inMemory only built the definition of a rebuilt machine"
        }
    }

    It 'no operation is required only for a rebuild' {
        @($script:map.operations | Where-Object { $_.PSObject.Properties['requiredFor'] } | ForEach-Object { [string]$_.requiredFor }) |
            Should -Not -Contain 'rebuild'
    }

    It 'the module calls neither Remove-AzVM nor New-AzVM, nor builds a definition for one' {
        foreach ($gone in 'Remove-AzVM', 'New-AzVM', 'New-AzVMConfig', 'Set-AzVMOSDisk', 'Set-AzVMBootDiagnostic', 'Set-AzVMSecurityProfile', 'Set-AzVmUefi', 'Add-AzVMNetworkInterface') {
            $script:moduleCommands | Should -Not -Contain $gone
        }
    }

    It 'THE KEPT RIGHT: networkInterfaces/join/action stays in the migration role, on the resize (Update-AzVM)' {
        $resize = @($script:map.operations | Where-Object { $_.cmdlet -eq 'Update-AzVM' })
        $resize.Count | Should -Be 1
        $resize[0].role | Should -Be 'execute'
        @($resize[0].actions) | Should -Contain 'Microsoft.Network/networkInterfaces/join/action'
        $resize[0].why | Should -Match 'networkInterfaces/join/action'
        $resize[0].why | Should -Match 'LinkedAuthorizationFailed'
        $script:executeActions | Should -Contain 'Microsoft.Network/networkInterfaces/join/action'
    }

    It 'THE KEPT RIGHT: the Preview still reads the preview feature (TEMP-DISK-PREVIEW-ROLE-1)' {
        $preview = @($script:map.operations | Where-Object { @($_.actions) -contains 'Microsoft.Features/providers/features/read' })
        $preview.Count | Should -Be 1
        $preview[0].requiredFor | Should -Be 'preview'
    }

    It 'the stop for a missing permission no longer says a rebuild deletes the machine' {
        InModuleScope VmMigrationFactory {
            $m = Format-VmfMissingActionsMessage -Missing @('Microsoft.Compute/virtualMachines/write') -Scope '/subscriptions/0/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
            $m | Should -Not -Match 'rebuild'
            $m | Should -Not -Match 'deleted'
            $m | Should -Match 'Microsoft.Compute/virtualMachines/write'
            $m | Should -Match 'VMF Migration role'
        }
    }
}

Describe 'REBUILD-REMOVE-ROLE-1: the functions only the rebuild called are gone' {
    It '<_> is not in the module' -ForEach @(
        # The azureops calls of the rebuild.
        'New-VmfVmFromCapture', 'Remove-VmfVmShell', 'Set-VmfDeleteOptionsDetach', 'Get-VmfDefinitionState', 'Get-VmfManagedDiskState',
        'Assert-VmfCaptureRebuildable', 'Get-VmfRebuildConfigExtras', 'New-VmfSubResourceModel', 'Set-VmfVmPatchSettings',
        # The engine helpers that ran after a rebuild.
        'Invoke-VmfRebuildPatchSettings', 'Write-VmfIdentityDeletedLine', 'Get-VmfRebuildPatchRequest', 'Test-VmfPatchImageRefusal',
        # The acceptance's follow-ups, which the engine no longer makes.
        'Get-VmfRebuildFollowUps', 'Get-VmfCapturedDcrNames', 'Get-VmfRebuildExtensionNames', 'Get-VmfRebuildLinkField', 'Test-VmfRebuildLinkHas',
        'Test-VmfSiteRecoveryExtension', 'Test-VmfPatchModeByPlatform', 'Get-VmfCapturedSystemIdentity', 'Get-VmfVmSqlVirtualMachine',
        # The scan's read of the data collection rule associations.
        'Read-VmfVmDcrAssociationList', 'Get-VmfVmDataCollectionRuleAssociations', 'Get-VmfDataCollectionRuleAssociationsByVm'
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ n = $_ } { param($n) Get-Command $n -ErrorAction SilentlyContinue } |
            Should -BeNullOrEmpty -Because "$_ served only the rebuild"
    }

    It 'no file of the module names a removed function in its code' {
        $gone = 'New-VmfVmFromCapture|Remove-VmfVmShell|Set-VmfDeleteOptionsDetach|Get-VmfDefinitionState|Get-VmfManagedDiskState|Invoke-VmfRebuildPatchSettings|Write-VmfIdentityDeletedLine|Get-VmfDataCollectionRuleAssociationsByVm'
        $hits = @(Get-ChildItem $script:moduleRoot -Filter *.ps1 -Recurse | Where-Object { (Get-VmfCodeOnly -Path $_.FullName) -match $gone } | ForEach-Object Name)
        $hits -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'REBUILD-REMOVE-ROLE-1: the scan reads no data collection rule association' {
    It 'neither role holds Microsoft.Insights/dataCollectionRuleAssociations/read' {
        @($script:allActions | Where-Object { $_ -match 'dataCollectionRuleAssociations' }) | Should -BeNullOrEmpty
    }

    It 'the scan does not ask for them, and says nothing about them' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:moduleRoot 'Public' 'Invoke-VmfAssessment.ps1')
        $code | Should -Not -Match 'DataCollectionRuleAssociations'
        $code | Should -Not -Match 'data collection rule associations'
    }

    It 'a machine record has no list of associations, and the record takes none' {
        $rec = Global:RrrRecord
        # REBUILD-REMOVE-SCAN-EXT-1 (v15): no rebuildLinks at all, so no list in it.
        $rec.PSObject.Properties.Name | Should -Not -Contain 'rebuildLinks'
        InModuleScope VmMigrationFactory { (Get-Command Get-VmfAssessmentRecord).Parameters.ContainsKey('DataCollectionRuleAssociations') | Should -BeFalse }
    }

    It 'the assessment contract is version 12' {
        InModuleScope VmMigrationFactory { Get-VmfAssessmentSchemaVersion | Should -Be 17 }
        $s = Get-Content $script:schemaPath -Raw | ConvertFrom-Json -Depth 40
        $s.properties.schemaVersion.const | Should -Be 17
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match 'assessment v11 -> v12 \(2026-11-07, REBUILD-REMOVE-ROLE-1\)'
    }

    It 'the migration note names the change' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match 'assessment v11 -> v12 \(2026-11-07, REBUILD-REMOVE-ROLE-1\)'
    }
}
