#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# MACHINE-PICK-1: a person chooses WHICH machines a migration moves, before
# their targets.
#
# A scan of a resource group, a subscription or a management group finds every
# machine there, and until this change every machine that could move went into
# the migration flow: the only way to leave one out was to take it out of a
# wave. Set-VmfMachineChoice saves the list (machine-choices.json, beside the
# assessment). Only a chosen machine may have a target, only chosen machines
# are planned, and the engine's plan operation refuses to plan without a list -
# the same way it refuses without targets (ADVISOR-1).
#
# TARGETS-NO-LIST-1: targets are never saved before the list, and saved
# targets never stand for it.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:McSku([string]$Name, [string]$TempMb = '0', [string]$Gens = 'V2') {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
    }
    function Global:McVm([string]$Name, [string]$Size, [string]$Gen, [string]$Arch, [string]$Controller, [string]$Class, [string[]]$Blockers) {
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
    # A reviewed assessment with its target options: two machines that can move
    # on v6 (app-01, web-02), a Generation 1 machine that can move on v5 only
    # (legacy-01), and one already on NVMe that has no supported series (new-09).
    function Global:McReviewed {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-mc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $rp -Leaf); generatedUtc = '2026-10-02T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}
            vms = @((McVm 'app-01' 'Standard_D2ds_v4' 'V2' 'scsi-temp' 'SCSI' 'ReadyAfterPrep' @()),
                    (McVm 'web-02' 'Standard_D2ds_v4' 'V2' 'scsi-temp' 'SCSI' 'ReadyAfterPrep' @()),
                    (McVm 'legacy-01' 'Standard_D2s_v4' 'V1' 'diskless' '' 'Blocked' @('gen1-requires-redeploy')),
                    (McVm 'new-09' 'Standard_D2ds_v6' 'V2' 'diskless' 'NVMe' 'ReadyNow' @())) }
        InModuleScope VmMigrationFactory -Parameters @{ r = $rp; d = $doc } {
            Initialize-VmfRun -RunPath $r -RunId (Split-Path $r -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $r -RelPath 'assessment.json' -Document $d -Depth 24
        }
        Approve-VmfAssessment -RunPath $rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfTargetAdvice -AssessmentPath (Join-Path $rp 'assessment.json') | Out-Null
        $rp
    }
    function Global:McId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
    # The version the SERVICE issues with a document (PLANVER-2): computed over
    # the stored text, exactly as GetStoreBlob does, never from parsed JSON.
    function Global:McVersion($rp, [string]$Name) {
        InModuleScope VmMigrationFactory -Parameters @{ r = $rp; n = $Name } {
            if (-not (Test-VmfStoreItem -RunPath $r -RelPath $n)) { return '' }
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $r -RelPath $n))
        }
    }
    function Global:McChoose($rp, [string[]]$Names, [string]$Previous = '') {
        Set-VmfMachineChoice -RunPath $rp -Machines @($Names | ForEach-Object { McId $_ }) `
            -ExpectedAdviceVersion (McVersion $rp 'target-advice.json') -ExpectedChoiceVersion $Previous `
            -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }
    }
    function Global:McTargets($rp, $Choices) {
        Set-VmfTargetChoice -RunPath $rp -Choices $Choices -Default 'current' `
            -ExpectedAdviceVersion (McVersion $rp 'target-advice.json') -ExpectedChoicesVersion (McVersion $rp 'target-choices.json') `
            -ExpectedMachinesVersion (McVersion $rp 'machine-choices.json') `
            -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }
    }
    function Global:McPlan($rp, $mig, [switch]$Require) {
        $a = @{ AssessmentPath = (Join-Path $rp 'assessment.json'); OutPath = $mig }
        if ($Require) { $a.RequireTargets = $true; $a.RequireMachineChoice = $true }
        New-VmfPlan @a
    }
    function Global:McPlanDoc($mig) { Get-Content (Join-Path $mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30 }
}
AfterAll {
    Remove-Item 'function:\McSku', 'function:\McVm', 'function:\McReviewed', 'function:\McId', 'function:\McVersion',
        'function:\McChoose', 'function:\McTargets', 'function:\McPlan', 'function:\McPlanDoc' -ErrorAction SilentlyContinue
}

Describe 'MACHINE-PICK-1: saving the chosen machines' {

    BeforeEach {
        $script:catalog = @((McSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (McSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (McSku 'Standard_D2ds_v6'), (McSku 'Standard_D2s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:rp = McReviewed
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'records who chose which machines, against which options and which scan' {
        $r = McChoose $script:rp @('app-01', 'legacy-01')
        $r.Chosen | Should -Be 2
        $doc = Get-Content (Join-Path $script:rp 'machine-choices.json') -Raw | ConvertFrom-Json -Depth 10
        $doc.savedBy.identity | Should -Be 'operator@example.com'
        @($doc.machines) | Should -Be @((McId 'app-01'), (McId 'legacy-01'))
        $doc.adviceVersion | Should -Be (McVersion $script:rp 'target-advice.json')
        $doc.assessmentHash | Should -Be ((Get-Content (Join-Path $script:rp 'target-advice.json') -Raw | ConvertFrom-Json).assessmentHash)
    }

    It 'the document matches its schema' {
        McChoose $script:rp @('app-01') | Out-Null
        Get-Content (Join-Path $script:rp 'machine-choices.json') -Raw |
            Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'machine-choices.schema.json') | Should -BeTrue
    }

    It 'a machine with a supported series on only one of them (some targets only) can be chosen' {
        { McChoose $script:rp @('legacy-01') } | Should -Not -Throw
    }

    It 'refuses a machine that cannot move on any series, and saves nothing' {
        # ALREADY-CURRENT-1: new-09 is on D2ds_v6, a size in the Current lifecycle
        # stage, so that is the reason it gives. The refusal for a machine with
        # no supported series is held in AlreadyCurrent.Tests.ps1.
        { McChoose $script:rp @('app-01', 'new-09') } | Should -Throw '400*new-09*cannot be chosen*Standard_D2ds_v6 is in the Current lifecycle stage*'
        Test-Path (Join-Path $script:rp 'machine-choices.json') | Should -BeFalse
    }

    It 'refuses an empty list, a machine not in the assessment, and a machine named twice' {
        { Set-VmfMachineChoice -RunPath $script:rp -Machines @() -ExpectedAdviceVersion (McVersion $script:rp 'target-advice.json') `
                -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = 't' } } | Should -Throw '400*at least one machine*'
        { McChoose $script:rp @('nobody') } | Should -Throw '400*not in this assessment*'
        { McChoose $script:rp @('app-01', 'app-01') } | Should -Throw '400*more than once*'
    }

    It 'refuses a list drawn from target options that were made again since - 409' {
        $read = McVersion $script:rp 'target-advice.json'
        New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') | Out-Null
        { Set-VmfMachineChoice -RunPath $script:rp -Machines @((McId 'app-01')) -ExpectedAdviceVersion $read `
                -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = 't' } } | Should -Throw '409*target options changed*'
    }

    It 'refuses to replace a list somebody else saved after this page read it - 409; with the version, it saves' {
        McChoose $script:rp @('app-01') | Out-Null
        { McChoose $script:rp @('web-02') } | Should -Throw '409*operator@example.com saved the machines*'
        McChoose $script:rp @('web-02') -Previous (McVersion $script:rp 'machine-choices.json') | Out-Null
        @((Get-Content (Join-Path $script:rp 'machine-choices.json') -Raw | ConvertFrom-Json).machines) | Should -Be @((McId 'web-02'))
    }

    It 'the version check and the write are one step: a write between them is refused, not overwritten' {
        McChoose $script:rp @('app-01') | Out-Null
        $read = McVersion $script:rp 'machine-choices.json'
        $file = Join-Path $script:rp 'machine-choices.json'
        $script:original = Get-Content $file -Raw
        # Another writer lands after the check: the check still reads the text
        # this page read, and the stored text has changed under it.
        Set-Content $file ($script:original -replace '"operator@example.com"', '"raced@example.com"') -NoNewline
        Mock -ModuleName VmMigrationFactory Read-VmfTextDocument -ParameterFilter { $Path -like '*machine-choices.json' } { $script:original }
        { McChoose $script:rp @('web-02') -Previous $read } | Should -Throw '409*'
        (Get-Content $file -Raw) | Should -Match 'raced@example.com' -Because 'the other writer''s list is still there'
    }

    It 'the FIRST save is create-only: a list another writer created after the check is refused, not overwritten' {
        # Review finding 9. The existence check says there is no list; another
        # writer creates one before this save writes.
        $file = Join-Path $script:rp 'machine-choices.json'
        McChoose $script:rp @('app-01') | Out-Null
        $theirs = Get-Content $file -Raw
        Mock -ModuleName VmMigrationFactory Test-VmfStoreItem -ParameterFilter { $RelPath -eq 'machine-choices.json' } { $false }
        { McChoose $script:rp @('web-02') } | Should -Throw '409*same time*'
        Get-Content $file -Raw | Should -Be $theirs -Because 'the other writer''s list is still there'
    }

    It 'refuses a migration - machines are chosen on the assessment' {
        InModuleScope VmMigrationFactory -Parameters @{ r = $script:rp } {
            $m = Read-VmfStoreJson -RunPath $r -RelPath 'run.json' -Depth 6
            $m.kind = 'migration'
            Write-VmfStoreJson -RunPath $r -RelPath 'run.json' -Document $m -Depth 6
        }
        { McChoose $script:rp @('app-01') } | Should -Throw '400*is a migration*'
    }

    It 'refuses when the target options are not written yet' {
        Remove-Item (Join-Path $script:rp 'target-advice.json')
        { Set-VmfMachineChoice -RunPath $script:rp -Machines @((McId 'app-01')) -ExpectedAdviceVersion 'x' `
                -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = 't' } } | Should -Throw '400*target options*not written*'
    }
}

Describe 'MACHINE-PICK-1: only a chosen machine may have a target' {

    BeforeEach {
        $script:catalog = @((McSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (McSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (McSku 'Standard_D2ds_v6'), (McSku 'Standard_D2s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:rp = McReviewed
        McChoose $script:rp @('app-01', 'legacy-01') | Out-Null
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'refuses a target for a machine that was not chosen' {
        { McTargets $script:rp @(@{ vmId = (McId 'web-02'); option = 'v6' }) } | Should -Throw '400*web-02*not chosen for this migration*'
        Test-Path (Join-Path $script:rp 'target-choices.json') | Should -BeFalse
    }

    # MANA-LINUX-KERNEL-1 raised the targets to v5 (the kernel choice); v5 holds every v4 field.
    It 'records the version of the machines the targets were saved against, at schema version 5' {
        McTargets $script:rp @(@{ vmId = (McId 'app-01'); option = 'v6' }) | Out-Null
        $doc = Get-Content (Join-Path $script:rp 'target-choices.json') -Raw | ConvertFrom-Json
        $doc.schemaVersion | Should -Be 9 -Because 'TARGETS-NO-LIST-1 made the targets v9: the list is always named'
        $doc.machinesVersion | Should -Be (McVersion $script:rp 'machine-choices.json')
        Get-Content (Join-Path $script:rp 'target-choices.json') -Raw |
            Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-choices.schema.json') | Should -BeTrue
    }

    It 'counts a machine with no target out of the chosen machines, not out of the whole scan' {
        (McTargets $script:rp @(@{ vmId = (McId 'app-01'); option = 'v6' })).NoTarget | Should -Be 1
    }

    It 'refuses targets chosen from a page that read other machines - 409' {
        $stale = McVersion $script:rp 'machine-choices.json'
        McChoose $script:rp @('app-01') -Previous $stale | Out-Null
        { Set-VmfTargetChoice -RunPath $script:rp -Choices @(@{ vmId = (McId 'app-01'); option = 'v6' }) -Default 'current' `
                -ExpectedAdviceVersion (McVersion $script:rp 'target-advice.json') -ExpectedMachinesVersion $stale `
                -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = 't' } } | Should -Throw '409*machines*changed*'
    }

    It 'TARGETS-NO-LIST-1: an assessment with no list saves no target - 400' {
        Remove-Item (Join-Path $script:rp 'machine-choices.json')
        { McTargets $script:rp @(@{ vmId = (McId 'web-02'); option = 'v6' }) } | Should -Throw '400: Choose the machines for this migration first*'
        Test-Path (Join-Path $script:rp 'target-choices.json') | Should -BeFalse
    }
}

Describe 'MACHINE-PICK-1: the plan holds only the chosen machines' {

    BeforeEach {
        $script:catalog = @((McSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (McSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (McSku 'Standard_D2ds_v6'), (McSku 'Standard_D2s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:rp = McReviewed
        $script:mig = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-mcm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    }
    AfterEach { foreach ($d in $script:rp, $script:mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } } }

    It 'plans the chosen machines only; a machine left out gets no entry, no target and no wave' {
        McChoose $script:rp @('app-01', 'legacy-01') | Out-Null
        McTargets $script:rp @(@{ vmId = (McId 'app-01'); option = 'v6' }, @{ vmId = (McId 'legacy-01'); option = 'v5' }) | Out-Null
        McPlan $script:rp $script:mig -Require | Out-Null
        $plan = McPlanDoc $script:mig
        @($plan.entries | ForEach-Object { $_.vmId }) | Sort-Object | Should -Be @((McId 'app-01'), (McId 'legacy-01'))
        (@($plan.entries) | Where-Object vmId -eq (McId 'app-01')).wave | Should -Not -Be 'unscheduled'
        (@($plan.entries) | Where-Object vmId -eq (McId 'legacy-01')).target.size | Should -Be 'Standard_D2s_v5'
    }

    It 'the machines left out stay in the assessment the migration carries' {
        McChoose $script:rp @('app-01') | Out-Null
        McTargets $script:rp @(@{ vmId = (McId 'app-01'); option = 'v6' }) | Out-Null
        McPlan $script:rp $script:mig -Require | Out-Null
        @((Get-Content (Join-Path $script:mig 'assessment.json') -Raw | ConvertFrom-Json).vms).Count | Should -Be 4
    }

    It 'a chosen machine with no target saved is in the plan, not moved, and the plan says why' {
        McChoose $script:rp @('app-01', 'web-02') | Out-Null
        McTargets $script:rp @(@{ vmId = (McId 'app-01'); option = 'v6' }) | Out-Null
        McPlan $script:rp $script:mig -Require | Out-Null
        $web = @((McPlanDoc $script:mig).entries) | Where-Object vmId -eq (McId 'web-02')
        $web.path | Should -Be 'MANUAL'
        $web.wave | Should -Be 'unscheduled'
        @($web.planNotes) -join ' ' | Should -Match 'No target was chosen'
    }

    It 'a chosen blocked machine with no target keeps its real reason' {
        McChoose $script:rp @('app-01', 'legacy-01') | Out-Null
        McTargets $script:rp @(@{ vmId = (McId 'app-01'); option = 'v6' }) | Out-Null
        McPlan $script:rp $script:mig -Require | Out-Null
        $legacy = @((McPlanDoc $script:mig).entries) | Where-Object vmId -eq (McId 'legacy-01')
        $legacy.path | Should -Be 'MANUAL'
        @($legacy.planNotes) -join ' ' | Should -Not -Match 'No target was chosen'
    }

    It 'the list travels with the migration, as the targets do' {
        McChoose $script:rp @('app-01') | Out-Null
        McTargets $script:rp @(@{ vmId = (McId 'app-01'); option = 'v6' }) | Out-Null
        McPlan $script:rp $script:mig -Require | Out-Null
        (Get-Content (Join-Path $script:mig 'machine-choices.json') -Raw) |
            Should -Be (Get-Content (Join-Path $script:rp 'machine-choices.json') -Raw) -Because 'copied as the stored text'
    }

    It 'the engine''s plan operation, with no machines chosen and no targets, is refused and says what to do' {
        { McPlan $script:rp $script:mig -Require } | Should -Throw '*No machine was chosen*Choose the machines*'
        Test-Path (Join-Path $script:mig 'plan.json') | Should -BeFalse
    }

    It 'with machines chosen and no targets, it is refused for the targets, as ADVISOR-1 has it' {
        McChoose $script:rp @('app-01') | Out-Null
        { McPlan $script:rp $script:mig -Require } | Should -Throw '*No target was chosen*'
    }

    It 'refuses targets saved before the machines were chosen again' {
        McChoose $script:rp @('app-01') | Out-Null
        McTargets $script:rp @(@{ vmId = (McId 'app-01'); option = 'v6' }) | Out-Null
        McChoose $script:rp @('app-01', 'web-02') -Previous (McVersion $script:rp 'machine-choices.json') | Out-Null
        { McPlan $script:rp $script:mig -Require } | Should -Throw '*machines were chosen again*Save the targets again*'
        Test-Path (Join-Path $script:mig 'plan.json') | Should -BeFalse
    }

    It 'refuses a list saved against a different scan of the machines' {
        McChoose $script:rp @('app-01') | Out-Null
        McTargets $script:rp @(@{ vmId = (McId 'app-01'); option = 'v6' }) | Out-Null
        $file = Join-Path $script:rp 'machine-choices.json'
        $c = Get-Content $file -Raw | ConvertFrom-Json -Depth 10
        $c.assessmentHash = ('f' * 64)
        $c | ConvertTo-Json -Depth 10 | Set-Content $file
        # The targets were bound to the list as it was; bind them to this one so
        # the scan is the only thing that differs.
        $t = Get-Content (Join-Path $script:rp 'target-choices.json') -Raw | ConvertFrom-Json -Depth 20
        $t.machinesVersion = McVersion $script:rp 'machine-choices.json'
        $t | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $script:rp 'target-choices.json')
        { McPlan $script:rp $script:mig -Require } | Should -Throw '*machines were chosen on a different scan*'
    }

    It 'TARGETS-NO-LIST-1: targets with no list are refused at the save, and the plan never takes saved targets for the list' {
        { Set-VmfTargetChoice -RunPath $script:rp -Choices @(@{ vmId = (McId 'app-01'); option = 'v6' }) `
            -Default 'current' -ExpectedAdviceVersion (McVersion $script:rp 'target-advice.json') `
            -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = 't' } } | Should -Throw '400: Choose the machines for this migration first. Then choose their targets.'
        Test-Path (Join-Path $script:rp 'target-choices.json') | Should -BeFalse
        # A file of that shape, put in the store by hand: the plan refuses it,
        # with and without the list requirement, and writes nothing.
        McChoose $script:rp @('app-01') | Out-Null
        McTargets $script:rp @(@{ vmId = (McId 'app-01'); option = 'v6' }) | Out-Null
        Remove-Item (Join-Path $script:rp 'machine-choices.json')
        { McPlan $script:rp $script:mig -Require } | Should -Throw '*No machine was chosen for this migration yet*'
        { McPlan $script:rp $script:mig } | Should -Throw '*have no list of machines*'
        Test-Path (Join-Path $script:mig 'plan.json') | Should -BeFalse
    }

    It 'TARGETS-NO-LIST-1: targets saved by an earlier version of the file are refused by the plan' {
        McChoose $script:rp @('app-01') | Out-Null
        McTargets $script:rp @(@{ vmId = (McId 'app-01'); option = 'v6' }) | Out-Null
        $file = Join-Path $script:rp 'target-choices.json'
        $doc = Get-Content $file -Raw | ConvertFrom-Json
        $doc.schemaVersion = 8
        $doc | ConvertTo-Json -Depth 10 | Set-Content $file -Encoding utf8NoBOM
        { McPlan $script:rp $script:mig -Require } | Should -Throw '*saved by an earlier version of this product*'
        Test-Path (Join-Path $script:mig 'plan.json') | Should -BeFalse
    }
    # REPORT-AUTO-1 MOVED this. The report's engineering appendix, where the
    # scanned machines were listed, is gone; the migration record holds the
    # count of machines not in this migration, by the same rule.
    It 'the record counts the machines left out as not in this migration, never ready (review finding 1)' {
        McChoose $script:rp @('app-01') | Out-Null
        McTargets $script:rp @(@{ vmId = (McId 'app-01'); option = 'v6' }) | Out-Null
        McPlan $script:rp $script:mig -Require | Out-Null
        $rec = InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig } { param($m) Get-VmfMigrationRecordFromStore -RunPath $m -Reason 'downloaded' }
        $rec.assessment.notInMigration | Should -Be 3 -Because 'web-02, legacy-01 and new-09 were not chosen; app-01 was'
        @($rec.machines | ForEach-Object { $_.name }) | Should -Be @('app-01') -Because 'a machine left out is not one of the migration''s machines'
    }

    It 'a command-line plan with no list and no targets plans every machine' {
        McPlan $script:rp $script:mig | Out-Null
        @((McPlanDoc $script:mig).entries).Count | Should -Be 4
    }

    It 'the hosted engine requires the list on every plan, even a request that names one series (review finding 3)' {
        # Code only (Get-VmfCodeOnly): a commented-out line must not pass.
        $entry = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1')
        $branch = [regex]::Match($entry, "(?s)'plan' \{(.*?)\n    \}").Groups[1].Value
        $branch | Should -Match '(?m)^\s*\$planParams\.RequireMachineChoice = \$true\s*$' -Because 'set on its own line, outside the series branch'
        $branch | Should -Match 'else \{ \$planParams\.RequireTargets = \$true \}'
    }
}

Describe 'MACHINE-PICK-1: the service saves the list for the signed-in user' {

    BeforeAll {
        function Global:McPrincipal([string]$Role) {
            $claims = @(@{ typ = 'preferred_username'; val = 'person@example.com' }, @{ typ = 'roles'; val = $Role })
            $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
            ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
        }
    }
    AfterAll { Remove-Item 'function:\McPrincipal' -ErrorAction SilentlyContinue }

    BeforeEach {
        $script:catalog = @((McSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (McSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (McSku 'Standard_D2ds_v6'), (McSku 'Standard_D2s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:rp = McReviewed
        $script:body = @{ AdviceVersion = (McVersion $script:rp 'target-advice.json'); ChoiceVersion = ''; Machines = @((McId 'app-01')) }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'an operator saves; the identity is the signed-in user' {
        $a = $script:body
        Invoke-VmfFacadeSetMachines -Principal (McPrincipal 'Vmf.Operator') -StorePath $script:rp @a | Out-Null
        (Get-Content (Join-Path $script:rp 'machine-choices.json') -Raw | ConvertFrom-Json).savedBy.identity | Should -Be 'person@example.com'
    }

    It 'a viewer may not, and nor may an approver' {
        $a = $script:body
        { Invoke-VmfFacadeSetMachines -Principal (McPrincipal 'Vmf.Viewer') -StorePath $script:rp @a } | Should -Throw '403*'
        { Invoke-VmfFacadeSetMachines -Principal (McPrincipal 'Vmf.Approver') -StorePath $script:rp @a } | Should -Throw '403*'
        Test-Path (Join-Path $script:rp 'machine-choices.json') | Should -BeFalse
    }

    It 'stale options or a newer save come back as 409, a machine that cannot move as 400' {
        $stale = @{} + $script:body; $stale.AdviceVersion = 'old'
        { Invoke-VmfFacadeSetMachines -Principal (McPrincipal 'Vmf.Operator') -StorePath $script:rp @stale } | Should -Throw '409*'
        $bad = @{} + $script:body; $bad.Machines = @((McId 'new-09'))
        { Invoke-VmfFacadeSetMachines -Principal (McPrincipal 'Vmf.Operator') -StorePath $script:rp @bad } | Should -Throw '400*'
    }

    It 'the targets save passes the version of the machines the page read' {
        $a = $script:body
        Invoke-VmfFacadeSetMachines -Principal (McPrincipal 'Vmf.Operator') -StorePath $script:rp @a | Out-Null
        $t = @{ Default = 'current'; AdviceVersion = (McVersion $script:rp 'target-advice.json'); ChoicesVersion = ''
            Choices = @([pscustomobject]@{ vmId = (McId 'app-01'); option = 'v6' }) }
        { Invoke-VmfFacadeSetTargets -Principal (McPrincipal 'Vmf.Operator') -StorePath $script:rp @t } | Should -Throw '409*machines*'
        Invoke-VmfFacadeSetTargets -Principal (McPrincipal 'Vmf.Operator') -StorePath $script:rp @t `
            -MachinesVersion (McVersion $script:rp 'machine-choices.json') | Out-Null
        (Get-Content (Join-Path $script:rp 'target-choices.json') -Raw | ConvertFrom-Json).machinesVersion | Should -Be (McVersion $script:rp 'machine-choices.json')
    }

    It 'the route is POST assessments/{runId}/machines, and the handler reads every field the page sends' {
        $fj = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostSetMachines' 'function.json') -Raw | ConvertFrom-Json
        $http = @($fj.bindings) | Where-Object type -eq 'httpTrigger'
        $http.route | Should -Be 'assessments/{runId}/machines'
        @($http.methods) | Should -Be @('post')
        $run = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostSetMachines' 'run.ps1')
        foreach ($k in 'machines', 'adviceVersion', 'machinesVersion') { $run | Should -Match "\`$body\.$k\b" }
        Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostSetTargets' 'run.ps1') | Should -Match '\$body\.machinesVersion\b'
    }
}

Describe 'STEP-LOG-4: a line that cannot be written, after the assessment''s documents are saved' {
    BeforeEach {
        $script:catalog = @((McSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (McSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (McSku 'Standard_D2ds_v6'), (McSku 'Standard_D2s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:rp = McReviewed
        $script:mig = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-mcm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    }
    AfterEach { foreach ($d in $script:rp, $script:mig) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } } }

    It 'the target options are written and returned when their line cannot be written' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'advice' } { throw 'The store did not answer.' }
        $r = New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') -WarningVariable w -WarningAction SilentlyContinue
        $r.Machines | Should -Be 4
        Test-Path (Join-Path $script:rp 'target-advice.json') | Should -BeTrue
        (@($w | ForEach-Object { [string]$_ }) -join ' ') | Should -BeLike "*'advice ok' could not be written*"
    }

    It 'the chosen machines are saved and returned when their line cannot be written' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'machines' } { throw 'The store did not answer.' }
        $r = McChoose $script:rp @('app-01', 'legacy-01') 3>$null
        $r.Chosen | Should -Be 2
        @((Get-Content (Join-Path $script:rp 'machine-choices.json') -Raw | ConvertFrom-Json).machines).Count | Should -Be 2
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'machines' } -Times 1 -Exactly
    }

    It 'the targets are saved and returned when their line cannot be written' {
        McChoose $script:rp @('app-01') | Out-Null
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'targets' } { throw 'The store did not answer.' }
        $r = McTargets $script:rp @(@{ vmId = (McId 'app-01'); option = 'v6' }) 3>$null
        $r.Saved | Should -Be 1
        Test-Path (Join-Path $script:rp 'target-choices.json') | Should -BeTrue
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'targets' } -Times 1 -Exactly
    }

    It 'the plan is saved and returned, and the list is told, when its line cannot be written' {
        Mock -ModuleName VmMigrationFactory Update-VmfRunSummary { $true }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'plan' } { throw 'The store did not answer.' }
        $r = New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -WarningVariable w -WarningAction SilentlyContinue
        $r.Total | Should -BeGreaterThan 0
        Test-Path (Join-Path $script:mig 'plan.json') | Should -BeTrue
        (@($w | ForEach-Object { [string]$_ }) -join ' ') | Should -BeLike "*'plan ok' could not be written*"
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -ParameterFilter { $Reason -eq 'planSaved' } -Times 1 -Exactly
    }
}