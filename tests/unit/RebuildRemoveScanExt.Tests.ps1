#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REBUILD-REMOVE-SCAN-EXT-1: the scan reads no extension list for an acceptance
# that is gone.
#
# REBUILD-ACCEPT-1 made the scan read every extension of every machine, ask
# each subscription's effective permissions when the answer was empty, and
# write the record rebuildLinks, so the acceptance of a rebuild could list what
# the rebuild deleted. The rebuild and its acceptance are removed
# (2026-11-07), and the plan stopped carrying rebuildLinks (plan-entry v29). The
# read stayed: Azure calls that drive no work, and a report line that names a
# screen that does not exist.
#
# Since 2026-11-11: nothing is public before 1.0, so no installation holds an
# assessment from an earlier version. The read, the record, the notRead
# subject and its words go outright, with no reader for the old shape
# (assessment v15).
#
# The read of extensions as such STAYS: Azure Disk Encryption, the SAP
# extension, the SQL IaaS Agent hint and PRECHECK's list of extensions all use
# Microsoft.Compute/virtualMachines/extensions/read, so the permission map
# keeps it.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:moduleRoot = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
    $script:schemaPath = Join-Path $script:repoRoot 'schemas' 'assessment.schema.json'
    $script:vmIdText = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1'

    function Global:RrseScan {
        $row = [pscustomobject]@{
            id = $script:vmIdText
            name = 'vm1'; resourceGroup = 'rg-app'; location = 'centralus'; zones = $null
            sku = 'Standard_D2ds_v4'; os = 'Windows'; gen = 'V2'; diskController = 'SCSI'
            osName = 'Windows Server 2022 Datacenter'; imagePublisher = 'MicrosoftWindowsServer'; imageOffer = 'WindowsServer'; imageSku = '2022-datacenter-g2'
            dataDiskCount = 0; nicCount = 0; nicIds = @(); dataDisks = @(); tags = @{}; patchMode = 'AutomaticByPlatform'
            osDiskManagedId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/os'
        }
        InModuleScope VmMigrationFactory -Parameters @{ row = $row } {
            param($row)
            Mock Get-VmfFleetInventory { , @($row) }
            Mock Get-VmfSkuCatalog { , @() }
            Mock Get-VmfMachineImageNvme { @{ Nvme = $null; Note = $null } }
            Mock Get-VmfNicFacts { @{ Accelerated = @{}; ClusterHints = @{} } }
            Mock Get-VmfSqlIaaSAgentVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            # Counted in the module scope: a scan that asks for the extension
            # read, or lists extensions, shows here.
            $script:rrsePermReads = 0; $script:rrseExtLists = 0
            Mock Get-VmfEffectivePermissions { $script:rrsePermReads++; , @() }
            Mock Invoke-VmfResourceGraphQuery {
                if ([string]$Body.query -match '(?i)virtualmachines/extensions') { $script:rrseExtLists++ }
                [pscustomobject]@{ data = @() }
            }
            Mock Get-VmfAvdSessionHostIds { @{ Ids = @{}; PoolTypes = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfManagedPlatformGroups { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSqlVirtualMachines { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfDiskShareMap { @{ Disks = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfResourceGroupOwners { @{ Groups = @{ '00000000-0000-0000-0000-000000000000/rg-app' = '' }; Verified = $true; Detail = 'mocked' } }
            $out = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rrse-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            try {
                Invoke-VmfAssessment -Scope @{ Subscriptions = @('00000000-0000-0000-0000-000000000000') } -OutPath $out | Out-Null
                $text = Get-Content (Join-Path $out 'assessment.json') -Raw
                $events = (@(Read-VmfEvents -RunPath $out) | ConvertTo-Json -Depth 10 -Compress)
                @{ Text = $text; Doc = ($text | ConvertFrom-Json -Depth 20); Events = [string]$events; PermReads = $script:rrsePermReads; ExtLists = $script:rrseExtLists }
            }
            finally { if (Test-Path $out) { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue } }
        }
    }
    function Global:RrseRecord {
        InModuleScope VmMigrationFactory -Parameters @{ id = $script:vmIdText } {
            param($id)
            $vm = [pscustomobject]@{ id = $id; name = 'vm1'; resourceGroup = 'rg-app'; location = 'centralus'; sku = 'Standard_D4ds_v4'
                os = 'Windows'; gen = 'V2'; dataDiskCount = 0; nicCount = 1; patchMode = 'AutomaticByPlatform' }
            Get-VmfAssessmentRecord -Vm $vm -SkuEntry $null -SqlVms @{ $id.ToLowerInvariant() = @{ id = 'x' } }
        }
    }
}

AfterAll {
    foreach ($fn in 'RrseScan', 'RrseRecord') { Remove-Item "function:\$fn" -ErrorAction SilentlyContinue }
}

Describe 'REBUILD-REMOVE-SCAN-EXT-1: the scan reads no extension list for the acceptance of a rebuild' {
    BeforeAll { $script:scan = RrseScan }

    It 'the module has no function that lists every extension of every machine' {
        InModuleScope VmMigrationFactory { Get-Command Get-VmfVmExtensionsByVm -ErrorAction SilentlyContinue } | Should -BeNullOrEmpty
        InModuleScope VmMigrationFactory { Get-Command Test-VmfExtensionReadHeld -ErrorAction SilentlyContinue } | Should -BeNullOrEmpty
    }

    It 'a scan lists no extension of every machine, and asks no effective permissions for the read' {
        $script:scan.ExtLists | Should -Be 0
        $script:scan.PermReads | Should -Be 0
    }

    It 'a scan writes no rebuildLinks on a machine' {
        $vm = @($script:scan.Doc.vms)[0]
        $vm | Should -Not -BeNullOrEmpty
        $vm.PSObject.Properties.Name | Should -Not -Contain 'rebuildLinks'
        $script:scan.Text | Should -Not -Match 'rebuildLinks'
    }

    It 'a scan writes no notRead subject for the extensions, and no line about the acceptance of a rebuild' {
        @($script:scan.Doc.notRead | Where-Object { $_.subject -eq 'rebuildLinks' }).Count | Should -Be 0
        $script:scan.Events | Should -Not -Match 'acceptance of a rebuild'
        $script:scan.Events | Should -Not -Match 'virtual machine extensions'
    }

    It 'the assessment is version 15, and the document the scan wrote passes the schema' {
        $script:scan.Doc.schemaVersion | Should -Be 17
        $script:scan.Text | Test-Json -SchemaFile $script:schemaPath | Should -BeTrue
    }

    It 'the record of a machine has no rebuildLinks, and takes no extension list' {
        $rec = RrseRecord
        $rec.PSObject.Properties.Name | Should -Not -Contain 'rebuildLinks'
        $rec.PSObject.Properties.Name | Should -Contain 'identityType' -Because 'the record itself was made'
        $params = (InModuleScope VmMigrationFactory { Get-Command Get-VmfAssessmentRecord }).Parameters.Keys
        $params | Should -Not -Contain 'VmExtensions'
        $params | Should -Not -Contain 'ExtensionsUnreadSubscriptions'
    }

    It 'the inventory query reads no patch mode: only rebuildLinks used it' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:moduleRoot 'Private' 'assess' 'Discovery.ps1')
        $query = [regex]::Match($code, "(?s)\`$script:VmfArgQuery = @'(.*?)'@").Groups[1].Value
        $query | Should -Match '\| project ' -Because 'the query itself was found'
        $query | Should -Not -Match 'patchMode'
    }

    It 'no code in the module or the dashboard writes or reads rebuildLinks' {
        $files = @(Get-ChildItem $script:moduleRoot -Filter *.ps1 -Recurse) +
            @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter *.js -File)
        $hits = @($files | Where-Object { (Get-VmfCodeOnly -Path $_.FullName) -match 'rebuildLinks' } | ForEach-Object Name)
        $hits | Should -BeNullOrEmpty
    }
}

Describe 'REBUILD-REMOVE-SCAN-EXT-1: the assessment report names no acceptance of a rebuild' {
    It 'the run report has no words for the subject, in the engine' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:moduleRoot 'Private' 'report' 'NotReadReport.ps1')
        $code | Should -Not -Match 'rebuildLinks'
        $code | Should -Not -Match 'acceptance of a rebuild'
    }

    It 'the run report has no words for the subject, on the page' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'assessment-report.js')
        $code | Should -Not -Match 'rebuildLinks'
        $code | Should -Not -Match 'acceptance of a rebuild'
    }

    It 'the subjects the scan still writes keep their words' {
        $html = InModuleScope VmMigrationFactory {
            ConvertTo-VmfNotReadReportHtml -NotRead @([pscustomobject]@{ subject = 'clusterHints'; detail = 'x' })
        }
        $html | Should -Match 'Cluster hints\.'
    }
}

Describe 'REBUILD-REMOVE-SCAN-EXT-1: the assessment schema v15 has no rebuildLinks' {
    BeforeAll { $script:schema = Get-Content $script:schemaPath -Raw | ConvertFrom-Json -Depth 40 }

    It 'the version is 15 in the module and in the schema' {
        InModuleScope VmMigrationFactory { Get-VmfAssessmentSchemaVersion } | Should -Be 17
        $script:schema.properties.schemaVersion.const | Should -Be 17
    }

    It 'a machine record has no rebuildLinks property, and no rule names it' {
        $script:schema.properties.vms.items.properties.PSObject.Properties.Name | Should -Not -Contain 'rebuildLinks'
        ($script:schema.allOf | ConvertTo-Json -Depth 40) | Should -Not -Match 'rebuildLinks'
    }

    It 'the migration note names the change' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match '## assessment v14 -> v15 \(2026-11-11, REBUILD-REMOVE-SCAN-EXT-1\)'
    }

    It 'a v15 document with rebuildLinks on a machine is refused' {
        $rec = RrseRecord | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        $rec | Add-Member -Force -NotePropertyName rebuildLinks -NotePropertyValue ([ordered]@{ extensions = @(); sqlVirtualMachine = $false })
        $doc = [ordered]@{ schemaVersion = 17; runId = 'r'; generatedUtc = '2026-11-11T00:00:00Z'
            scope = [ordered]@{ subscriptions = @(); managementGroup = $null; tagFilter = $null; resourceGroups = @() }
            summary = @{}; vms = @($rec) }
        ($doc | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $script:schemaPath -ErrorAction SilentlyContinue | Should -BeFalse
        $rec.PSObject.Properties.Remove('rebuildLinks')
        ($doc | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $script:schemaPath | Should -BeTrue
    }
}

Describe 'REBUILD-REMOVE-SCAN-EXT-1: the extension read stays for the checks that use it' {
    It 'the permission map keeps virtualMachines/extensions/read in the assess role' {
        $map = Get-Content (Join-Path $script:moduleRoot 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json -Depth 20
        $assess = @($map.operations | Where-Object role -EQ 'assess' | ForEach-Object { @($_.actions) })
        $assess | Should -Contain 'Microsoft.Compute/virtualMachines/extensions/read'
    }

    It 'the SQL IaaS Agent hint and the SAP check still read extensions through Resource Graph' {
        InModuleScope VmMigrationFactory { Get-Command Get-VmfSqlIaaSAgentVmIds -ErrorAction SilentlyContinue } | Should -Not -BeNullOrEmpty
        InModuleScope VmMigrationFactory { Get-Command Get-VmfSapSystemVmIds -ErrorAction SilentlyContinue } | Should -Not -BeNullOrEmpty
        InModuleScope VmMigrationFactory { Get-Command Get-VmfVmExtensions -ErrorAction SilentlyContinue } | Should -Not -BeNullOrEmpty
    }
}
