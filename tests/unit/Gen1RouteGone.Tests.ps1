#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# GEN1-ROUTE-GONE-1: the target options name no Generation 1 route.
#
# Since 2026-10-31: the product does not support Generation 1 to 2 at all.
# GEN1-UPGRADE-1 was decided on 2026-10-05: not built, outside the scope of
# this tool. The target options still added an option 'gen1Route' to every
# Generation 1 machine, and the targets step showed it as "Microsoft
# Generation 1 route: Not available: Not built yet" - which says a route
# is coming. It is not.
#
# So the option is gone, not hidden: the engine does not write it, the schema
# does not allow it (target-advice v22), and the page has no words for it. A
# v21 file that still holds the option is refused by name and made again, as
# every earlier version is (Set-VmfTargetChoice, Set-VmfMachineChoice, and
# the page reads it as not made).

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:schemaFile = Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json'

    function Global:GrSku([string]$Name, [string]$TempMb = '0', [string]$Gens = 'V2') {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
    }
    function Global:GrVm([string]$Name, [string]$Size, [string]$Gen, [string]$Arch, [string]$Controller, [string]$Class, [string[]]$Blockers) {
        [ordered]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @(); classification = $Class; gen = $Gen
            os = 'Linux'; osVersion = '22_04-lts-gen2'; sourceSize = $Size; sourceDiskArch = $Arch
            sourceTempDisks = $(if ($Arch -eq 'scsi-temp') { 1 } else { 0 }); diskController = $Controller
            dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; platformManaged = $false; iacManaged = $false
            hibernationEnabled = $false; availabilitySetId = ''; identityType = 'None'; tags = @{ app = $Name }
            blockers = @($Blockers); prepNeeded = @()
        }
    }
    function Global:GrAdvise([object[]]$Vms, [hashtable]$Catalog) {
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($Vms | ForEach-Object { [pscustomobject]$_ }) }
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = $Catalog } } {
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c -RegionsNotRead @()
        }
    }
    function Global:GrCatalog([switch]$NoGen1V5) {
        $c = @{}
        $v5Gens = if ($NoGen1V5) { 'V2' } else { 'V1,V2' }
        foreach ($s in @((GrSku 'Standard_D2ds_v5' '76800' $v5Gens), (GrSku 'Standard_D2s_v5' '0' $v5Gens),
                         (GrSku 'Standard_D2ds_v6'), (GrSku 'Standard_D2s_v6'), (GrSku 'Standard_D2ds_v7'), (GrSku 'Standard_D2s_v7'))) {
            $c[$s.Name] = $s
        }
        $c
    }
    function Global:GrId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
    function Global:GrVersion($rp, [string]$Name) {
        InModuleScope VmMigrationFactory -Parameters @{ p = $rp; n = $Name } {
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $p -RelPath $n))
        }
    }
    # A reviewed assessment with its options written, then the options made
    # into the v21 shape: the Generation 1 machine holds the route option.
    function Global:GrReviewedWithOldAdvice {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-gr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $rp -Leaf); generatedUtc = '2026-10-31T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}
            vms = @((GrVm 'app-01' 'Standard_D2ds_v4' 'V2' 'scsi-temp' 'SCSI' 'ReadyAfterPrep' @()),
                    (GrVm 'legacy-01' 'Standard_D2s_v4' 'V1' 'diskless' '' 'Blocked' @('gen1-requires-redeploy'))) }
        InModuleScope VmMigrationFactory -Parameters @{ p = $rp; d = $doc } {
            Initialize-VmfRun -RunPath $p -RunId (Split-Path $p -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $p -RelPath 'assessment.json' -Document $d -Depth 24
        }
        Approve-VmfAssessment -RunPath $rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((GrCatalog).Values) }
        New-VmfTargetAdvice -AssessmentPath (Join-Path $rp 'assessment.json') | Out-Null
        $file = Join-Path $rp 'target-advice.json'
        $advice = Get-Content $file -Raw | ConvertFrom-Json -Depth 40
        $advice.schemaVersion = 21
        $g1 = @($advice.machines | Where-Object name -eq 'legacy-01')[0]
        $g1.options = @($g1.options) + @([pscustomobject](GrOldRouteOption))
        Set-Content -LiteralPath $file -Value ($advice | ConvertTo-Json -Depth 40) -NoNewline
        $rp
    }
    # The option exactly as v21 wrote it (schemas/samples, before this item).
    function Global:GrOldRouteOption {
        [ordered]@{
            option = 'gen1Route'; supported = $false; notSupported = @('not-built-yet')
            targetSize = $null; sizeUnverified = $false; path = $null; blockers = @(); prep = @()
            move = 'gen1-route'; rebuild = $false; tempDisksFrom = $null; tempDisksTo = $null
            targetStage = $null; stageChange = 'unknown'
            acceleratedNetworking = [ordered]@{ required = $null; mayUseMana = $null; turnsOn = $null; keptOn = $null; keptOnWhy = $null }
            stops = @(); sizeChoices = @(); premiumDisks = $null; burstableEnds = $null; burstableKept = $null; burstableTarget = $null
            processorChange = $null; processor = $null; identity = $null
        }
    }
}
AfterAll {
    Remove-Item 'function:\GrSku', 'function:\GrVm', 'function:\GrAdvise', 'function:\GrCatalog', 'function:\GrId', 'function:\GrVersion',
        'function:\GrReviewedWithOldAdvice', 'function:\GrOldRouteOption' -ErrorAction SilentlyContinue
}

Describe 'GEN1-ROUTE-GONE-1: the engine writes no Generation 1 route' {

    It 'a Generation 1 machine that a v5 size fits has v5, v6 and v7 only, and starts on v5' {
        $vm = GrVm 'g1' 'Standard_D2s_v4' 'V1' 'diskless' '' 'Blocked' @('gen1-requires-redeploy')
        $m = @((GrAdvise @($vm) (GrCatalog)).machines)[0]
        @($m.options.option) | Should -Be @('v5', 'v6', 'v7')
        (@($m.options) | Where-Object option -eq 'v5').supported | Should -BeTrue
        foreach ($s in 'v6', 'v7') {
            @((@($m.options) | Where-Object option -eq $s).notSupported) | Should -Be @('gen1-requires-redeploy') -Because "$s needs Generation 2"
        }
        $m.start.current | Should -Be 'v5'
        $m.start.extended | Should -Be 'v5'
    }

    It 'a Generation 1 machine that no v5 size fits has v5, v6 and v7 only, none supported, and no start' {
        $vm = GrVm 'g1' 'Standard_D2s_v4' 'V1' 'diskless' '' 'Blocked' @('gen1-requires-redeploy')
        $m = @((GrAdvise @($vm) (GrCatalog -NoGen1V5)).machines)[0]
        @($m.options.option) | Should -Be @('v5', 'v6', 'v7')
        @($m.options | Where-Object supported).Count | Should -Be 0
        $m.start.current | Should -BeNullOrEmpty
        $m.start.extended | Should -BeNullOrEmpty
    }

    It 'no move is gen1-route and no reason is not-built-yet, and the advice matches its schema' {
        $vms = @((GrVm 'g1' 'Standard_D2s_v4' 'V1' 'diskless' '' 'Blocked' @('gen1-requires-redeploy')),
                 (GrVm 'g2' 'Standard_D2ds_v4' 'V2' 'scsi-temp' 'SCSI' 'ReadyAfterPrep' @()))
        $advice = GrAdvise $vms (GrCatalog)
        $opts = @($advice.machines | ForEach-Object { @($_.options) })
        @($opts | Where-Object { $_.move -eq 'gen1-route' }).Count | Should -Be 0
        @($opts | Where-Object { @($_.notSupported) -contains 'not-built-yet' }).Count | Should -Be 0
        $advice.schemaVersion | Should -Be 34
        $advice | ConvertTo-Json -Depth 30 | Test-Json -SchemaFile $script:schemaFile | Should -BeTrue
    }
}

Describe 'GEN1-ROUTE-GONE-1: target-advice v22 does not allow the route' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:schema = Get-Content $script:schemaFile -Raw | ConvertFrom-Json -Depth 40
    }

    It 'the version is the one in use (24), in the engine, the schema and the page' {
        InModuleScope VmMigrationFactory { Get-VmfTargetAdviceSchemaVersion | Should -Be 34 }
        $script:schema.properties.schemaVersion.const | Should -Be 34
        $script:schema.properties.schemaVersion.description | Should -Match '\b22 \(GEN1-ROUTE-GONE-1' -Because 'REBUILD-PICKER-1 put v23 first, and TEMP-DISK-PREVIEW-1 v24'
        ((Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))) | Should -Match 'const TARGET_ADVICE_VERSION = 34;'
    }

    It 'the series are v5, v6 and v7 only' {
        @($script:schema.'$defs'.series.enum) | Should -Be @('v5', 'v6', 'v7')
    }

    It 'no move is gen1-route, and no reason is not-built-yet' {
        @($script:schema.'$defs'.option.properties.move.enum) | Should -Not -Contain 'gen1-route'
        @($script:schema.'$defs'.option.properties.move.enum) | Should -Contain 'scsi-resize'
        @($script:schema.'$defs'.reason.enum) | Should -Not -Contain 'not-built-yet'
        @($script:schema.'$defs'.reason.enum) | Should -Contain 'gen1-requires-redeploy'
    }

    It 'the schema names no Generation 1 route in its words' {
        $script:schema.description | Should -Not -Match '(?i)route'
    }

    It 'a v21 document that holds the route does not pass the v22 schema' {
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'target-advice.sample.json') -Raw | ConvertFrom-Json -Depth 40
        $sample | ConvertTo-Json -Depth 40 | Test-Json -SchemaFile $script:schemaFile | Should -BeTrue -Because 'the shipped sample is valid'
        $g1 = @($sample.machines | Where-Object gen -eq 'V1')[0]
        $g1 | Should -Not -BeNullOrEmpty -Because 'the sample has a Generation 1 machine'
        $g1.options = @($g1.options) + @([pscustomobject](GrOldRouteOption))
        $sample | ConvertTo-Json -Depth 40 | Test-Json -SchemaFile $script:schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
    }
}

Describe 'GEN1-ROUTE-GONE-1: a v21 file that holds the route is refused by name and made again' {

    BeforeEach { $script:rp = GrReviewedWithOldAdvice }
    AfterEach { Remove-Item $script:rp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'the plant landed: the stored file is v21 and holds the route' {
        $text = Get-Content (Join-Path $script:rp 'target-advice.json') -Raw
        $text | Should -Match '"schemaVersion": 21'
        $text | Should -Match '"gen1Route"'
    }

    It 'saving targets on it is refused - 409, older version' {
        { Set-VmfTestTargetChoice -RunPath $script:rp -Choices @(@{ vmId = (GrId 'legacy-01'); option = 'v5' }) -Default 'current' `
                -ExpectedAdviceVersion (GrVersion $script:rp 'target-advice.json') `
                -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } } |
            Should -Throw '409*older version*'
    }

    It 'choosing machines on it is refused - 409, older version' {
        { Set-VmfMachineChoice -RunPath $script:rp -Machines @((GrId 'legacy-01')) `
                -ExpectedAdviceVersion (GrVersion $script:rp 'target-advice.json') `
                -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } } |
            Should -Throw '409*older version*'
    }

    It 'making the options again writes the version in use (v24), without the route' {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((GrCatalog).Values) }
        New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') | Out-Null
        $text = Get-Content (Join-Path $script:rp 'target-advice.json') -Raw
        ($text | ConvertFrom-Json).schemaVersion | Should -Be 34
        $text | Should -Not -Match 'gen1Route|gen1-route|not-built-yet'
    }

    It 'the page reads a file of another version as not made, so it never shows the route' {
        $wiz = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html') -Language CStyle
        $wiz | Should -Match ([regex]::Escape('av.doc?.schemaVersion === TARGET_ADVICE_VERSION ? av.doc : null'))
    }
}

Describe 'GEN1-ROUTE-GONE-1: no operator word names the route' {

    It 'the targets step has no words or handling for it' {
        $wiz = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html') -Language CStyle
        foreach ($word in 'gen1Route', 'gen1-route', 'not-built-yet', 'optGen1Route', 'kRoute', 'Not built yet', 'Generation 1 route') {
            $wiz | Should -Not -Match ([regex]::Escape($word)) -Because "the page still says '$word'"
        }
    }

    It 'the engine and the save do not name it' {
        foreach ($rel in @(('src', 'VmMigrationFactory', 'Private', 'plan', 'Advice.ps1'),
                           ('src', 'VmMigrationFactory', 'Public', 'Set-VmfMachineChoice.ps1'),
                           ('src', 'VmMigrationFactory', 'Private', 'validate', 'KernelUpdate.ps1'))) {
            $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot @rel)
            $code | Should -Not -Match 'gen1Route|gen1-route|not-built-yet' -Because ($rel -join '/')
        }
    }

    It 'no file the product ships, nor a sample or fixture, names it - comments included' {
        $roots = @(
            (Join-Path $script:repoRoot 'src'),
            (Join-Path $script:repoRoot 'schemas'),
            (Join-Path $script:repoRoot 'docs' 'manual'),
            (Join-Path $script:repoRoot 'tests' 'fixtures'))
        $hits = foreach ($root in $roots) {
            Get-ChildItem -LiteralPath $root -Recurse -File |
                Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1', '.json', '.html', '.js', '.md', '.sh', '.css' } |
                # Case-sensitive, so this item's own ID (GEN1-ROUTE-GONE-1) in a
                # migration note is not read as the move gen1-route.
                Select-String -Pattern 'gen1Route', 'gen1-route', 'not-built-yet', 'Not built yet', 'Generation 1 route' -SimpleMatch -CaseSensitive |
                ForEach-Object { "$($_.Path):$($_.LineNumber)" }
        }
        @($hits) | Should -BeNullOrEmpty
    }

    It 'the manual says what a Generation 1 machine is shown, and no route' {
        $plan = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'use' 'plan.md') -Raw
        $plan | Should -Match ([regex]::Escape('Its **Details** show v6 and v7 as **Not available**, with the reason **Generation 1 machine**.'))
        $plan | Should -Not -Match '(?i)generation 1 route|not built yet'
    }
}
