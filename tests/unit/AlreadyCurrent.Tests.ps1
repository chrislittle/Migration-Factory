#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# ALREADY-CURRENT-1: the scan records the lifecycle stage of each machine's
# CURRENT size, so the pages can show a machine on a Current size as Current.
#
# Lab finding 81 (2026-11-05): Choose the machines and the assessment gave a red
# "Cannot yet" to machines already on D2ds_v6, and counted them with the
# machines that cannot move. The rule since 2026-11-06: a machine whose current size
# Microsoft puts in the Current lifecycle stage is in the group Current, with
# the line "<size> is in the Current lifecycle stage." - read from the
# lifecycle data the product already holds (Get-VmfSizeLifecycleStage,
# target-families.json lifecycle), never from the size name.
#
# The stage goes into the assessment record (sourceLifecycle, assessment v10)
# by that one function, so the pages read a fact and hold no twin of the size
# rules. tests/fixtures/already-current.json holds the cases; the page side is
# tests/js/already-current.test.js.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'already-current.json') -Raw | ConvertFrom-Json -Depth 20
    $script:schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') -Raw | ConvertFrom-Json -Depth 40

    # A Windows machine on a supported Marketplace image, in the shape the
    # scan reads from Resource Graph.
    function Global:AcRecord([string]$Size) {
        $vm = [pscustomobject]@{
            id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/ac'
            name = 'ac'; resourceGroup = 'rg'; location = 'centralus'
            sku = $Size; os = 'Windows'; gen = 'V2'; diskController = 'SCSI'; osName = 'Windows Server 2022 Datacenter'
            imagePublisher = 'MicrosoftWindowsServer'; imageOffer = 'WindowsServer'; imageSku = '2022-datacenter-smalldisk-g2'
            osDiskManagedId = '/s/rg/disks/ac'; nicCount = 1; nicIds = @()
        }
        InModuleScope VmMigrationFactory -Parameters @{ v = $vm } { Get-VmfAssessmentRecord -Vm $v }
    }
}
AfterAll { Remove-Item 'function:\AcRecord' -ErrorAction SilentlyContinue }

Describe 'ALREADY-CURRENT-1: the scan records the lifecycle stage of the current size' {

    It 'records the stage the lifecycle data gives, for every fixture size: <name>' -ForEach @(
        (Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'already-current.json') -Raw | ConvertFrom-Json -Depth 20).cases |
            Where-Object { -not ($_.PSObject.Properties['engineless'] -and $_.engineless) } |
            ForEach-Object { @{ name = $_.name; size = $_.sourceSize; stage = $_.engine } }) {
        $r = AcRecord $size
        if ($null -eq $stage) {
            $r.sourceLifecycle | Should -BeNullOrEmpty -Because 'a size the data does not hold has no stage - unknown is never Current'
        }
        else {
            $r.sourceLifecycle.stage | Should -BeExactly $stage
        }
    }

    It 'records the basis too, from the same function' {
        $want = InModuleScope VmMigrationFactory { Get-VmfSizeLifecycleStage -SizeName 'Standard_F2als_v7' }
        $r = AcRecord 'Standard_F2als_v7'
        $r.sourceLifecycle.stage | Should -BeExactly 'Current'
        $r.sourceLifecycle.basis | Should -BeExactly $want.Basis
        $r.sourceLifecycle.basis | Should -BeExactly 'derived'
    }

    It 'takes the stage from Get-VmfSizeLifecycleStage, never from the size name' {
        Mock -ModuleName VmMigrationFactory Get-VmfSizeLifecycleStage { @{ Stage = 'Current'; Basis = 'stated'; Source = 'lifecycle-overview'; How = '' } } -ParameterFilter { $SizeName -eq 'Standard_D2ds_v4' }
        (AcRecord 'Standard_D2ds_v4').sourceLifecycle.stage | Should -BeExactly 'Current' -Because 'the data decides, so a v4 size the data called Current would be Current'
        Mock -ModuleName VmMigrationFactory Get-VmfSizeLifecycleStage { $null } -ParameterFilter { $SizeName -eq 'Standard_D2ds_v6' }
        (AcRecord 'Standard_D2ds_v6').sourceLifecycle | Should -BeNullOrEmpty -Because 'and a v6 name the data does not hold is not Current'
    }

    It 'records it for a machine the scan blocks too - the pages decide what the group is' {
        $vm = [pscustomobject]@{
            id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/rebuilt'
            name = 'rebuilt'; resourceGroup = 'rg'; location = 'centralus'
            sku = 'Standard_D2ds_v6'; os = 'Windows'; gen = 'V2'; diskController = 'NVMe'; osName = 'Windows Server 2022 Datacenter'
            imagePublisher = ''; imageOffer = ''; imageSku = ''
            osDiskManagedId = '/s/rg/disks/rebuilt'; nicCount = 1; nicIds = @()
        }
        $r = InModuleScope VmMigrationFactory -Parameters @{ v = $vm } { Get-VmfAssessmentRecord -Vm $v }
        @($r.blockers) | Should -Contain 'image-not-supported' -Because 'a machine rebuilt around its disks has no image record in Azure (lab finding 81)'
        $r.sourceLifecycle.stage | Should -BeExactly 'Current'
    }
}

Describe 'ALREADY-CURRENT-1: a machine on a Current size cannot be chosen to migrate' {
    BeforeAll {
        # Target options written as the engine writes them, with one machine on
        # a Current size that the options still give a supported series - so
        # only the Current rule can refuse it. The page's twin is canChoose in
        # wizard.js (tests/js/already-current.test.js).
        $script:acRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ac-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $sub = '00000000-0000-0000-0000-000000000000'
        $script:acId = { param($n) "/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$n" }.GetNewClosure()
        $opt = @([ordered]@{ option = 'v7'; supported = $true })
        $advice = [ordered]@{ schemaVersion = (InModuleScope VmMigrationFactory { Get-VmfTargetAdviceSchemaVersion }); assessmentId = 'scan-ac'; assessmentHash = 'x'
            machines = @(
                [ordered]@{ vmId = (& $script:acId 'on-v6'); name = 'on-v6'; sourceSize = 'Standard_D2ds_v6'; sourceStage = [ordered]@{ stage = 'Current'; basis = 'stated' }; options = $opt },
                [ordered]@{ vmId = (& $script:acId 'on-v5'); name = 'on-v5'; sourceSize = 'Standard_D2ds_v5'; sourceStage = [ordered]@{ stage = 'Extended'; basis = 'stated' }; options = $opt },
                [ordered]@{ vmId = (& $script:acId 'no-stage'); name = 'no-stage'; sourceSize = 'Standard_DC2as_v5'; sourceStage = $null; options = $opt },
                [ordered]@{ vmId = (& $script:acId 'no-series'); name = 'no-series'; sourceSize = 'Standard_D2s_v4'; sourceStage = [ordered]@{ stage = 'Extended'; basis = 'stated' }
                    options = @([ordered]@{ option = 'v6'; supported = $false }) }) }
        InModuleScope VmMigrationFactory -Parameters @{ r = $script:acRun; d = $advice } {
            Initialize-VmfRun -RunPath $r -RunId (Split-Path $r -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $r -RelPath 'target-advice.json' -Document $d -Depth 24
        }
        $script:acChoose = {
            param([string[]]$Names)
            $v = InModuleScope VmMigrationFactory -Parameters @{ r = $script:acRun } {
                Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $r -RelPath 'target-advice.json')) }
            Set-VmfMachineChoice -RunPath $script:acRun -Machines @($Names | ForEach-Object { & $script:acId $_ }) -ExpectedAdviceVersion $v `
                -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }
        }
    }
    AfterAll { if ($script:acRun -and (Test-Path $script:acRun)) { Remove-Item $script:acRun -Recurse -Force } }

    It 'refuses a machine whose size the target options put in the Current lifecycle stage, and saves nothing' {
        { & $script:acChoose @('on-v5', 'on-v6') } | Should -Throw "400*'on-v6'*Standard_D2ds_v6 is in the Current lifecycle stage*"
        Test-Path (Join-Path $script:acRun 'machine-choices.json') | Should -BeFalse
    }

    It 'a machine on an Extended size with no supported series is still refused for that' {
        { & $script:acChoose @('on-v5', 'no-series') } | Should -Throw '400*no-series*cannot move on any size series*'
    }

    It 'chooses a machine on an Extended size, and one whose stage the data does not hold' {
        (& $script:acChoose @('on-v5', 'no-stage')).Chosen | Should -Be 2
    }
}

Describe 'ALREADY-CURRENT-1: the assessment contract is version 10' {

    It 'the schema allows sourceLifecycle: stage and basis, or null, and does not require it' {
        $script:schema.properties.schemaVersion.const | Should -Be 17
        $p = $script:schema.properties.vms.items.properties.sourceLifecycle
        $p | Should -Not -BeNullOrEmpty
        @($p.type) | Should -Be @('object', 'null')
        $p.additionalProperties | Should -BeFalse
        @($p.properties.stage.enum) | Should -Be @('Current', 'Extended', 'End of Life', 'Retired')
        @($p.properties.basis.enum) | Should -Be @('stated', 'derived')
        @($script:schema.properties.vms.items.required) | Should -Not -Contain 'sourceLifecycle' -Because 'a v9 record has none'
        InModuleScope VmMigrationFactory { Get-VmfAssessmentSchemaVersion | Should -Be 17 }
    }

    It 'the schema stages are the stages the lifecycle data holds' {
        $data = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json -Depth 40
        @($script:schema.properties.vms.items.properties.sourceLifecycle.properties.stage.enum) | Should -Be @($data.lifecycle.stages)
        @($data.lifecycle.bySeries.basis | Sort-Object -Unique) | ForEach-Object {
            @($script:schema.properties.vms.items.properties.sourceLifecycle.properties.basis.enum) | Should -Contain $_
        }
    }

    It 'a generated record with a stage, and one without, are both valid' {
        foreach ($size in 'Standard_D2ds_v6', 'Standard_DC2as_v5') {
            $doc = [ordered]@{ schemaVersion = 17; runId = 'r'; generatedUtc = '2026-11-06T00:00:00Z'
                scope = [ordered]@{ subscriptions = @(); managementGroup = $null; tagFilter = $null; resourceGroups = @() }
                summary = @{}; vms = @(AcRecord $size) }
            Test-Json -Json ($doc | ConvertTo-Json -Depth 30) -SchemaFile (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') -ErrorAction Stop |
                Should -BeTrue -Because $size
        }
    }

    It 'a v9 assessment still reads; a newer one is refused' {
        InModuleScope VmMigrationFactory {
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 9 }) } | Should -Throw '*reads only version 17*'
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 10 }) } | Should -Throw '*reads only version 17*'
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 11 }) } | Should -Throw '*reads only version 17*'
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 12 }) } | Should -Throw '*reads only version 17*'
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 18 }) } | Should -Throw '*newer version*'
        }
    }

    It 'the migration note names the change' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match 'assessment v9 -> v10'
        $notes | Should -Match 'sourceLifecycle'
    }
}
