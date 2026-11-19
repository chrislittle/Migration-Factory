#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REBUILD-MOVE-HOST-1, rescoped on 2026-11-11.
#
#   - Dedicated hosts were never tested and are not part of 1.0, so a
#     machine on an Azure Dedicated Host (properties.host or
#     properties.hostGroup) is outside the scope of this tool.
#   - No machine with hibernation enabled is moved: a machine with
#     hibernation enabled (properties.additionalCapabilities.hibernationEnabled)
#     is outside the scope of this tool too.
#
# Both the way the scan leaves out a scale set member, an AKS node or a
# Virtual Desktop session host: Excluded (platformManaged), with the evidence
# in a note. And Checking stops a planned machine that Azure now shows on a
# dedicated host or with hibernation enabled, before any change, untouched.
#
# A hibernated machine has hibernation enabled (Microsoft's Hibernation
# overview, prerequisites: "Hibernation must be enabled on your VM"), so the
# old Checking stop for a hibernated power state (machineHibernated) is gone:
# the stop for hibernation enabled comes first for every such machine.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:hhSub = '00000000-0000-0000-0000-000000000000'
    $script:hhHost = "/subscriptions/$($script:hhSub)/resourceGroups/rg-hosts/providers/Microsoft.Compute/hostGroups/hg-contoso/hosts/host-01"
    $script:hhGroup = "/subscriptions/$($script:hhSub)/resourceGroups/rg-hosts/providers/Microsoft.Compute/hostGroups/hg-contoso"

    # One inventory row, in the shape the discovery query projects it.
    function Global:HhRow {
        param([string]$HostId = '', [string]$HostGroupId = '', [bool]$Hibernation = $false, [switch]$NoHostFields)
        $sub = '00000000-0000-0000-0000-000000000000'
        $row = [pscustomobject]@{
            id = "/subscriptions/$sub/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1"
            name = 'vm1'; resourceGroup = 'rg-app'; location = 'centralus'; zones = $null
            sku = 'Standard_D2ds_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'
            osName = 'ubuntu'
            imagePublisher = 'Canonical'; imageOffer = '0001-com-ubuntu-server-jammy'; imageSku = '22_04-lts-gen2'; imageId = ''
            communityGalleryImageId = ''; sharedGalleryImageId = ''; planPublisher = ''; planProduct = ''; planName = ''
            vmssId = ''; hibernationEnabled = $Hibernation; securityType = ''; dataDiskCount = 0; dataDisks = @()
            tags = $null; identityType = 'None'; identityPrincipalId = ''
            adeOsDiskEnabled = ''; licenseType = ''; osDiskManagedId = "/subscriptions/$sub/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1-os"
        }
        # A row from before this item has no host fields: not on a host.
        if (-not $NoHostFields) {
            $row | Add-Member -NotePropertyName hostId -NotePropertyValue $HostId
            $row | Add-Member -NotePropertyName hostGroupId -NotePropertyValue $HostGroupId
        }
        $row
    }
    function Global:HhSku {
        [pscustomobject]@{
            Name = 'Standard_D2ds_v4'; ResourceType = 'virtualMachines'; Family = 'StandardDDSv4Family'
            Capabilities = @([pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '76800' }, [pscustomobject]@{ Name = 'vCPUs'; Value = '2' })
            Restrictions = @()
        }
    }
    function Global:HhKnown {
        @{
            SapSystemVms = @{}; AvdSessionHosts = @{}; AvdPoolTypes = @{}; ManagedPlatformGroups = @{}
            SqlVms = @{}; DiskShares = @{}; NicClusterHints = @{}; SqlAgentVms = @{}
            ResourceGroupOwners = @{ '00000000-0000-0000-0000-000000000000/rg-app' = '' }
        }
    }
    # The machine as Get-VmfVmConfig returns it (the Get-AzVM shape).
    function Global:HhLiveVm {
        param([string]$HostId = '', [string]$HostGroupId = '', [AllowNull()]$Hibernation = $false, [switch]$NoCapabilities)
        [pscustomobject]@{
            Name = 'vm1'
            Host = $(if ($HostId) { [pscustomobject]@{ Id = $HostId } } else { $null })
            HostGroup = $(if ($HostGroupId) { [pscustomobject]@{ Id = $HostGroupId } } else { $null })
            AdditionalCapabilities = $(if ($NoCapabilities) { $null } else { [pscustomobject]@{ UltraSSDEnabled = $false; HibernationEnabled = $Hibernation } })
        }
    }
    $script:reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
    $script:stops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
}
AfterAll { Remove-Item 'function:\HhRow', 'function:\HhSku', 'function:\HhKnown', 'function:\HhLiveVm' -ErrorAction SilentlyContinue }

Describe 'REBUILD-MOVE-HOST-1: the scan reads the dedicated host and the host group' {

    It 'the discovery query projects hostId and hostGroupId from the machine''s own properties' {
        $q = InModuleScope VmMigrationFactory { $script:VmfArgQuery }
        $q | Should -Match 'hostId\s*=\s*tostring\(properties\.host\.id\)'
        $q | Should -Match 'hostGroupId\s*=\s*tostring\(properties\.hostGroup\.id\)'
        $project = ($q -split '\| project ')[1]
        $project | Should -Match '\bhostId\b'
        $project | Should -Match '\bhostGroupId\b'
    }
}

Describe 'REBUILD-MOVE-HOST-1: the scan excludes a machine on a dedicated host' {

    It 'a machine on a dedicated host is Excluded, and the note names the host and the host group' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (HhKnown); h = $script:hhHost; g = $script:hhGroup } {
            $rec = Get-VmfAssessmentRecord -Vm (HhRow -HostId $h -HostGroupId $g) -SkuEntry (HhSku) @f
            $rec.classification | Should -Be 'Excluded'
            $rec.platformManaged | Should -BeTrue
            $note = @($rec.notes) -join ' '
            $note | Should -Match "dedicated host 'host-01'"
            $note | Should -Match "host group 'hg-contoso'"
            $note | Should -Match 'A machine on a dedicated host is outside the scope of this tool\.'
        }
    }

    It 'a machine in a host group with automatic placement (no host in its model) is Excluded too' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (HhKnown); g = $script:hhGroup } {
            $rec = Get-VmfAssessmentRecord -Vm (HhRow -HostGroupId $g) -SkuEntry (HhSku) @f
            $rec.classification | Should -Be 'Excluded'
            (@($rec.notes) -join ' ') | Should -Match "host group 'hg-contoso'"
        }
    }

    It 'a machine with a host and no host group is Excluded' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (HhKnown); h = $script:hhHost } {
            $rec = Get-VmfAssessmentRecord -Vm (HhRow -HostId $h) -SkuEntry (HhSku) @f
            $rec.classification | Should -Be 'Excluded'
            (@($rec.notes) -join ' ') | Should -Match "dedicated host 'host-01'"
        }
    }

    It 'an ordinary machine is not excluded: <Name>' -TestCases @(
        @{ Name = 'empty host fields'; NoFields = $false }
        @{ Name = 'a row with no host fields'; NoFields = $true }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ f = (HhKnown); nf = $NoFields } {
            $rec = Get-VmfAssessmentRecord -Vm (HhRow -NoHostFields:$nf) -SkuEntry (HhSku) @f
            $rec.classification | Should -Not -Be 'Excluded'
            $rec.platformManaged | Should -BeFalse
            (@($rec.notes) -join ' ') | Should -Not -Match 'dedicated host'
        }
    }
}

Describe 'REBUILD-MOVE-HOST-1: the scan excludes a machine with hibernation enabled' {

    It 'a machine with hibernation enabled is Excluded, and the note says so' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (HhKnown) } {
            $rec = Get-VmfAssessmentRecord -Vm (HhRow -Hibernation $true) -SkuEntry (HhSku) @f
            $rec.classification | Should -Be 'Excluded'
            $rec.platformManaged | Should -BeTrue
            $rec.hibernationEnabled | Should -BeTrue
            (@($rec.notes) -join ' ') | Should -Match 'A machine with hibernation enabled is outside the scope of this tool\.'
        }
    }

    It 'the old note that promised a stop for a hibernated machine is gone' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (HhKnown) } {
            $rec = Get-VmfAssessmentRecord -Vm (HhRow -Hibernation $true) -SkuEntry (HhSku) @f
            (@($rec.notes) -join ' ') | Should -Not -Match 'engine parks'
        }
    }

    It 'a machine without hibernation is not excluded' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (HhKnown) } {
            $rec = Get-VmfAssessmentRecord -Vm (HhRow) -SkuEntry (HhSku) @f
            $rec.classification | Should -Not -Be 'Excluded'
            (@($rec.notes) -join ' ') | Should -Not -Match 'hibernation'
        }
    }
}

Describe 'REBUILD-MOVE-HOST-1: Checking stops a planned machine on a dedicated host or with hibernation enabled' {

    It 'a machine on a dedicated host stops untouched, and the stop names the host and the host group' {
        InModuleScope VmMigrationFactory -Parameters @{ v = (HhLiveVm -HostId $script:hhHost -HostGroupId $script:hhGroup) } {
            $stop = Get-VmfHostHibernationStop -Vm $v
            $stop.Next | Should -Be 'NEEDS_DECISION'
            $stop.Reason | Should -Be 'dedicatedHost'
            $stop.MachineState | Should -Be 'untouched'
            $stop.Detail | Should -Match "dedicated host 'host-01'"
            $stop.Detail | Should -Match "host group 'hg-contoso'"
            $stop.Detail | Should -Match 'Nothing on the machine changed\.$'
        }
    }

    It 'a machine in a host group only stops untouched' {
        InModuleScope VmMigrationFactory -Parameters @{ v = (HhLiveVm -HostGroupId $script:hhGroup) } {
            $stop = Get-VmfHostHibernationStop -Vm $v
            $stop.Reason | Should -Be 'dedicatedHost'
            $stop.Detail | Should -Match "host group 'hg-contoso'"
            $stop.Detail | Should -Not -Match "dedicated host '"
        }
    }

    It 'a machine on a host with no host group stops untouched' {
        InModuleScope VmMigrationFactory -Parameters @{ v = (HhLiveVm -HostId $script:hhHost) } {
            $stop = Get-VmfHostHibernationStop -Vm $v
            $stop.Reason | Should -Be 'dedicatedHost'
            $stop.Detail | Should -Not -Match 'host group'
        }
    }

    It 'a machine with hibernation enabled stops untouched' {
        InModuleScope VmMigrationFactory -Parameters @{ v = (HhLiveVm -Hibernation $true) } {
            $stop = Get-VmfHostHibernationStop -Vm $v
            $stop.Next | Should -Be 'NEEDS_DECISION'
            $stop.Reason | Should -Be 'hibernationEnabled'
            $stop.MachineState | Should -Be 'untouched'
            $stop.Detail | Should -Match 'Hibernation is enabled on this machine'
            $stop.Detail | Should -Match 'Nothing on the machine changed\.$'
        }
    }

    It 'an ordinary machine goes on: <Name>' -TestCases @(
        @{ Name = 'hibernation false'; Hib = $false; NoCap = $false }
        @{ Name = 'hibernation not set'; Hib = $null; NoCap = $false }
        @{ Name = 'no additional capabilities'; Hib = $false; NoCap = $true }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ v = (HhLiveVm -Hibernation $Hib -NoCapabilities:$NoCap) } {
            Get-VmfHostHibernationStop -Vm $v | Should -BeNullOrEmpty
        }
    }

    It 'PRECHECK asks it once, with the machine it read, beside the other out-of-scope stops' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $start = $code.IndexOf('function Invoke-VmfStepPrecheck')
        $pre = $code.Substring($start, $code.IndexOf('function Get-VmfSafetyAttempt') - $start)
        ([regex]::Matches($pre, 'Get-VmfHostHibernationStop')).Count | Should -Be 1
        $pre | Should -Match 'Get-VmfHostHibernationStop -Vm \$vm\s'
        $at = $pre.IndexOf('Get-VmfHostHibernationStop')
        $at | Should -BeGreaterThan $pre.IndexOf('$ownDisks = Get-VmfDataDiskScopeDetail')
        # Before any stop a person can accept, any RunCommand, any start and
        # the capture of the machine.
        foreach ($later in 'Read-VmfPrecheckExtensions', 'Get-VmfTempDiskContentStop', 'Get-VmfWorkloadCheckStop', 'Get-VmfVmCapture') {
            $pre.IndexOf($later) | Should -BeGreaterThan $at -Because $later
        }
    }

    It 'PRECHECK no longer has the stop for a hibernated power state' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $code | Should -Not -Match 'machineHibernated'
        $code | Should -Not -Match "-match 'hibernat'"
    }
}

Describe 'REBUILD-MOVE-HOST-1: the stop table and the reasons file' {

    It 'the stop <Code> is in the stop table: outside the scope of this tool, and the machine untouched' -TestCases @(
        @{ Code = 'dedicatedHost' }
        @{ Code = 'hibernationEnabled' }
    ) {
        $r = @($script:stops.reasons | Where-Object code -EQ $Code)
        $r.Count | Should -Be 1
        $r[0].retry | Should -Be 'outOfScope'
        $r[0].machine | Should -Be 'untouched'
        $r[0].meaning | Should -Match 'outside the scope of this tool'
        $r[0].meaning | Should -Match 'Nothing on the machine was changed'
        $r[0].title | Should -Match '\(not in scope\)$'
    }

    It 'the stop for a hibernated power state is gone from the stop table' {
        @($script:stops.reasons | Where-Object code -EQ 'machineHibernated').Count | Should -Be 0
    }

    It 'the excluded reason <Key> is in the reasons file, with Microsoft''s page' -TestCases @(
        @{ Key = 'dedicated-host'; Url = '^https://learn\.microsoft\.com/en-us/azure/virtual-machines/dedicated-hosts/overview$' }
        @{ Key = 'hibernation-enabled'; Url = '^https://learn\.microsoft\.com/en-us/azure/virtual-machines/hibernate-resume$' }
    ) {
        $e = $script:reasons.excluded.$Key
        $e | Should -Not -BeNullOrEmpty
        $e.docs.url | Should -Match $Url
        $e.meaning | Should -Match 'outside the scope of this tool'
        $e.title | Should -Not -BeNullOrEmpty
        $e.whatToDo | Should -Not -BeNullOrEmpty
    }
}

Describe 'REBUILD-MOVE-HOST-1: the words for a machine that is not eligible are true for every excluded machine' {

    # Review: these machines are Excluded with platformManaged, so every
    # sentence that names why a machine is not eligible must also cover a
    # machine outside the scope of this tool, not only a managed one.
    It 'the screen <File> says another service manages it, or it is outside the scope of this tool' -TestCases @(
        @{ File = 'assessment-report.js'; Pattern = "notEligibleWhy:\s*'([^']*)'" }
        @{ File = 'assessments.js'; Pattern = "notEligibleWhy:\s*'([^']*)'" }
        @{ File = 'migrations.js'; Pattern = "Excluded:\s*\['Not eligible',\s*'([^']*)'" }
    ) {
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' $File) -Raw
        $m = [regex]::Match($src, $Pattern)
        $m.Success | Should -BeTrue
        $m.Groups[1].Value | Should -Match 'outside the scope of this tool'
        $m.Groups[1].Value | Should -Match 'Another Azure service manages'
    }

    It 'the engine''s skip for an excluded machine does not call it platform-managed' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $code | Should -Not -Match 'Platform-managed member VM'
        $code | Should -Match 'or it is outside the scope of this tool'
    }
}