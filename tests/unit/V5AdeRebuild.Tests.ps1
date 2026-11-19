#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# V5-ADE-1: v5 is not offered to an encrypted machine whose v5 move is a rebuild.
#
# A v5 move keeps Azure Disk Encryption only IN PLACE. A rebuild makes a new
# machine around the encrypted disks without the extension that unlocks them,
# and the engine stops that at Checking (the adeCheck before any change). But
# the assessment and the targets step both offered v5 - "disk-encryption-
# present" names v6 and v7 only - so a person chose it, planned it, and met the
# stop in the change window. The rule since 2026-09-29: a move that does not
# support ADE is not offered.
#
# The rule sits in Resolve-VmfEntryTarget, which the target advice, the plan
# and the one-machine target change all use, so they cannot disagree.
#
# REBUILD-REMOVE-PLAN-1 (2026-11-07): the move that changes the kind of
# temporary disk is no longer a rebuild but the in-place upgrade (Preview),
# which nobody measured with Azure Disk Encryption. It stays refused for 1.0,
# so the rule stands under a new code, disk-encryption-preview.

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:AdeSku([string]$Name, [string]$TempMb = '0', [string]$Gens = 'V1,V2') {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                [pscustomobject]@{ Name = 'MemoryGB'; Value = '8' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
    }
    # The planner gives a machine with a temporary disk the v5 "d" size first,
    # so the move stays in place. A Windows v5 move is a rebuild only when the
    # region offers no such size - then the plain size, with no temporary disk,
    # changes the disk kind. -WithDSize is the usual region.
    function Global:AdeCatalog([switch]$WithDSize) {
        $c = @{}
        foreach ($s in @((AdeSku 'Standard_D2s_v3' '16384'), (AdeSku 'Standard_D2s_v5' '0'),
                (AdeSku 'Standard_D2ds_v6' '0' 'V2'), (AdeSku 'Standard_D2s_v6' '0' 'V2'))) { $c[$s.Name] = $s }
        if ($WithDSize) { $s = AdeSku 'Standard_D2ds_v5' '76800'; $c[$s.Name] = $s }
        $c
    }
    function Global:AdeVm([string]$Size = 'Standard_D2s_v3', [string]$Os = 'Windows', [switch]$Encrypted, [string]$Arch = 'scsi-temp') {
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/m"
            name = 'm'; location = 'centralus'; gen = 'V2'; os = $Os; osVersion = '2022-datacenter-g2'
            classification = $(if ($Encrypted) { 'Blocked' } else { 'ReadyAfterPrep' })
            blockers = @(if ($Encrypted) { 'disk-encryption-present' }); prepNeeded = @()
            sourceSize = $Size; sourceDiskArch = $Arch; sourceTempDisks = $(if ($Arch -eq 'scsi-temp') { 1 } else { 0 })
            diskController = 'SCSI'; dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; platformManaged = $false
        }
    }
    function Global:AdeTarget($Vm, [string]$Series, [switch]$WithDSize) {
        InModuleScope VmMigrationFactory -Parameters @{ v = $Vm; c = (AdeCatalog -WithDSize:$WithDSize); s = $Series } {
            param($v, $c, $s) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration $s
        }
    }
    function Global:AdeAdvice($Vm, [switch]$WithDSize) {
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($Vm) }
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = (AdeCatalog -WithDSize:$WithDSize) } } {
            param($d, $c) Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
    }
}
AfterAll { Remove-Item function:AdeSku, function:AdeCatalog, function:AdeVm, function:AdeTarget, function:AdeAdvice -ErrorAction SilentlyContinue }

Describe 'V5-ADE-1: the target of an encrypted machine' {
    It 'the shapes are what the test says: with no v5 d size in the region, this machine''s v5 move changes the kind of temporary disk (the Preview)' {
        (AdeTarget (AdeVm) 'v5').Path | Should -Be 'A'
        (AdeTarget (AdeVm) 'v5').Preview | Should -BeTrue
        (AdeTarget (AdeVm) 'v5').Mapping.Target | Should -Be 'Standard_D2s_v5'
        (AdeTarget (AdeVm) 'v5' -WithDSize).Path | Should -Be 'A' -Because 'the usual region offers D2ds_v5, which keeps the temporary disk'
    }

    It 'THE DEFECT: an encrypted machine whose v5 move changes the kind of temporary disk is not moved on v5, and says why' {
        $t = AdeTarget (AdeVm -Encrypted) 'v5'
        @($t.Blockers) | Should -Contain 'disk-encryption-preview'
        $t.Classification | Should -Be 'Blocked'
        $t.Path | Should -Be 'MANUAL' -Because 'it stays refused for 1.0'
        $t.Mapping.Target | Should -BeNullOrEmpty -Because 'no page draws an arrow to a size it is not going to'
        $t.Mapping.Reason | Should -Match 'Azure Disk Encryption.*in-place upgrade \(Preview\)'
    }

    It 'an encrypted machine whose v5 move is in place still moves: v5 keeps the encryption' {
        $t = AdeTarget (AdeVm -Encrypted) 'v5' -WithDSize
        $t.Path | Should -Be 'A'
        $t.Mapping.Target | Should -Be 'Standard_D2ds_v5'
        @($t.Blockers) | Should -Not -Contain 'disk-encryption-preview'
    }

    It 'a Linux machine always moves in place, so it keeps v5' {
        $t = AdeTarget (AdeVm -Os 'Linux' -Encrypted) 'v5'
        $t.Path | Should -Be 'A'
        @($t.Blockers).Count | Should -Be 0
    }

    It 'v6 is still closed by the scan''s own reason, and not twice' {
        $t = AdeTarget (AdeVm -Encrypted) 'v6'
        @($t.Blockers) | Should -Be @('disk-encryption-present')
    }
}

Describe 'V5-ADE-1: the targets step does not offer it' {
    It 'the v5 option is not supported, with the code the screen puts in words' {
        $m = (AdeAdvice (AdeVm -Encrypted)).machines[0]
        $v5 = $m.options | Where-Object option -EQ 'v5'
        $v5.supported | Should -BeFalse
        @($v5.notSupported) | Should -Contain 'disk-encryption-preview'
        $m.start.extended | Should -BeNullOrEmpty -Because 'no series is open to it: v6 and v7 are closed by the encryption'
    }

    It 'the same machine in place keeps v5 as its starting target' {
        $m = (AdeAdvice (AdeVm -Encrypted) -WithDSize).machines[0]
        ($m.options | Where-Object option -EQ 'v5').supported | Should -BeTrue
        $m.start.extended | Should -Be 'v5'
    }

    It 'the document matches its schema, at the version that knows the code' {
        $advice = AdeAdvice (AdeVm -Encrypted)
        $advice.schemaVersion | Should -Be (InModuleScope VmMigrationFactory { Get-VmfTargetAdviceSchemaVersion }) -Because 'the code that knows disk-encryption-preview writes it (v28 and later)'
        $advice | ConvertTo-Json -Depth 12 | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
    }

    It 'the schema change ships with its migration note (hard rule 1)' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match '## target-advice v3 -> v4 \(2026-09-29, V5-ADE-1\)'
        $notes | Should -Match '`disk-encryption-rebuild`'
        $notes | Should -Match '`disk-encryption-preview`'
    }

    It 'the refused option names no size, and is not a Preview' {
        $v5 = (AdeAdvice (AdeVm -Encrypted)).machines[0].options | Where-Object option -EQ 'v5'
        $v5.targetSize | Should -BeNullOrEmpty
        $v5.preview | Should -BeFalse
        $v5.Keys | Should -Not -Contain 'rebuild'
    }

    It 'the targets step has words for the code' {
        $page = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))
        $page | Should -Match "'disk-encryption-preview': '[^']{10,}'"
    }
}

# REPORT-AUTO-1 MOVED this from the report's engineering appendix into the
# migration record (machines[].assessment). Same rule; read where it is kept.
Describe 'V5-ADE-1: a planned machine the plan does not move is not called ready' {
    It 'the record shows it held back, with the plan''s reason in words' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ade-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/enc-01'
            $vm = [ordered]@{ vmId = $id; name = 'enc-01'; classification = 'Blocked'; gen = 'V2'; os = 'Windows'; sourceSize = 'Standard_D2s_v3'
                sourceDiskArch = 'scsi-temp'; diskController = 'SCSI'; blockers = @('disk-encryption-present'); prepNeeded = @(); platformManaged = $false }
            $why = 'This machine uses Azure Disk Encryption, and its move to v5 is a rebuild. The product does not rebuild an encrypted machine, so it does not move it.'
            $entry = [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'unscheduled'; appGroup = 'enc-01'
                assessment = [ordered]@{ classification = 'Blocked'; gen = 'V2'; os = 'Windows'; sourceSize = 'Standard_D2s_v3'; sourceDiskArch = 'scsi-temp'
                    location = 'centralus'; blockers = @('disk-encryption-present'); prepNeeded = @(); platformManaged = $false; dataDiskCount = 0; nicCount = 1; availabilitySetId = '' }
                target = [ordered]@{ size = $null; sizeAlternates = @(); diskArch = $null; tempDisks = $null; controller = 'SCSI'; zone = $null }
                path = 'MANUAL'; policy = [ordered]@{ targetGeneration = 'v5'; requireApproval = $true }; planNotes = @($why) }
            InModuleScope VmMigrationFactory -Parameters @{ p = $rp; a = ([ordered]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($vm); summary = @{} }); e = $entry } {
                Initialize-VmfRun -RunPath $p -RunId (Split-Path $p -Leaf) -Kind 'migration' | Out-Null
                Write-VmfStoreJson -RunPath $p -RelPath 'assessment.json' -Document $a -Depth 24
                Write-VmfStoreJson -RunPath $p -RelPath 'plan.json' -Document ([ordered]@{ schemaVersion = 4; entries = @($e) }) -Depth 24
            }
            $rec = InModuleScope VmMigrationFactory -Parameters @{ p = $rp } { param($p) Get-VmfMigrationRecordFromStore -RunPath $p -Reason 'downloaded' }
            $m = @($rec.machines | Where-Object { $_.name -eq 'enc-01' })[0]
            $m.assessment.classification | Should -Be 'Blocked' -Because 'judged by v5 alone it would read ready after preparation'
            (@($m.assessment.issues) -join ' ') | Should -Match 'does not rebuild an encrypted machine'
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }
}
