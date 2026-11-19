#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# ADVISOR-1 part 2a: each machine's chosen target is saved, and the plan is
# built from it.
#
# Part 1 wrote the options (target-advice.json). A person chooses from them;
# Set-VmfTargetChoice records who chose what, against which options, in
# target-choices.json beside the assessment. New-VmfPlan then resolves every
# machine against ITS OWN choice instead of one series for the whole plan - so
# a Generation 1 machine the scan blocked for v6 is planned on v5 and lands in
# a wave (GEN-V5-2), beside machines planned on v6.
#
# Only a SUPPORTED option can be saved. The choices are bound to the options
# they were made from and to the assessment that was reviewed.

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:TcSku([string]$Name, [string]$TempMb = '0', [string]$Gens = 'V2') {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
    }
    function Global:TcVm([string]$Name, [string]$Size, [string]$Gen, [string]$Arch, [string]$Controller, [string]$Class, [string[]]$Blockers) {
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
    # A reviewed assessment with its options written: a Generation 2 machine
    # (v5 and v6 both supported) and a Generation 1 machine (v5 only).
    function Global:TcReviewed([string[]]$AnOff = @()) {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-tc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $rp -Leaf); generatedUtc = '2026-09-26T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}
            vms = @((TcVm 'app-01' 'Standard_D2ds_v4' 'V2' 'scsi-temp' 'SCSI' 'ReadyAfterPrep' @()),
                    (TcVm 'legacy-01' 'Standard_D2s_v4' 'V1' 'diskless' '' 'Blocked' @('gen1-requires-redeploy')),
                    # Already on v6 and NVMe: no supported option, so never a choice.
                    (TcVm 'new-09' 'Standard_D2ds_v6' 'V2' 'diskless' 'NVMe' 'ReadyNow' @())) }
        foreach ($v in $doc.vms) { if ($v.name -in $AnOff) { $v.acceleratedNicCount = 0 } }
        InModuleScope VmMigrationFactory -Parameters @{ p = $rp; d = $doc } {
            Initialize-VmfRun -RunPath $p -RunId (Split-Path $p -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $p -RelPath 'assessment.json' -Document $d -Depth 24
        }
        Approve-VmfAssessment -RunPath $rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfTargetAdvice -AssessmentPath (Join-Path $rp 'assessment.json') | Out-Null
        $rp
    }
    function Global:TcAdvice($rp) { Get-Content (Join-Path $rp 'target-advice.json') -Raw | ConvertFrom-Json -Depth 30 }
    function Global:TcId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
    # The version the SERVICE issues with a document (PLANVER-2): computed over
    # the stored text, exactly as GetStoreBlob does, never from parsed JSON.
    function Global:TcVersion($rp, [string]$Name) {
        InModuleScope VmMigrationFactory -Parameters @{ p = $rp; n = $Name } {
            if (-not (Test-VmfStoreItem -RunPath $p -RelPath $n)) { return '' }
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $p -RelPath $n))
        }
    }
    function Global:TcSave($rp, $Choices, [string]$Default = 'current', [string]$Previous = '') {
        Set-VmfTestTargetChoice -RunPath $rp -Choices $Choices -Default $Default -ExpectedAdviceVersion (TcVersion $rp 'target-advice.json') `
            -ExpectedChoicesVersion $Previous -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }
    }
}
AfterAll { Remove-Item 'function:\TcSku', 'function:\TcVm', 'function:\TcReviewed', 'function:\TcAdvice', 'function:\TcId', 'function:\TcSave', 'function:\TcVersion' -ErrorAction SilentlyContinue }

Describe 'ADVISOR-1: saving the chosen targets' {

    BeforeEach {
        $script:catalog = @((TcSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (TcSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (TcSku 'Standard_D2ds_v6'), (TcSku 'Standard_D2s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:rp = TcReviewed
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'records who chose what, against which options, and whether it is the default or a person''s change' {
        $r = TcSave $script:rp @(@{ vmId = (TcId 'app-01'); option = 'v5' }, @{ vmId = (TcId 'legacy-01'); option = 'v5' })
        $r.Saved | Should -Be 2
        $doc = Get-Content (Join-Path $script:rp 'target-choices.json') -Raw | ConvertFrom-Json -Depth 20
        $doc.savedBy.identity | Should -Be 'operator@example.com'
        $doc.default | Should -Be 'current'
        $doc.adviceVersion | Should -Be (TcVersion $script:rp 'target-advice.json')
        $doc.assessmentHash | Should -Be ((TcAdvice $script:rp).assessmentHash)
        $app = @($doc.choices) | Where-Object vmId -eq (TcId 'app-01')
        $app.option | Should -Be 'v5'
        $app.source | Should -Be 'person' -Because 'the Current default starts app-01 on v6'
        (@($doc.choices) | Where-Object vmId -eq (TcId 'legacy-01')).source | Should -Be 'default' -Because 'v5 is where legacy-01 starts'
    }

    It 'the document matches its schema' {
        TcSave $script:rp @(@{ vmId = (TcId 'app-01'); option = 'v6' }) | Out-Null
        Get-Content (Join-Path $script:rp 'target-choices.json') -Raw |
            Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-choices.schema.json') | Should -BeTrue
    }

    It 'refuses an option that is not supported for the machine, and says why' {
        { TcSave $script:rp @(@{ vmId = (TcId 'legacy-01'); option = 'v6' }) } |
            Should -Throw '400*legacy-01*v6*gen1-requires-redeploy*'
        Test-Path (Join-Path $script:rp 'target-choices.json') | Should -BeFalse -Because 'nothing is saved when one choice is refused'
    }

    It 'refuses a machine that is not in the assessment, and a machine named twice' {
        { TcSave $script:rp @(@{ vmId = (TcId 'nobody'); option = 'v6' }) } | Should -Throw '*not in this assessment*'
        { TcSave $script:rp @(@{ vmId = (TcId 'app-01'); option = 'v6' }, @{ vmId = (TcId 'app-01'); option = 'v5' }) } |
            Should -Throw '*more than once*'
    }

    It 'refuses choices made from options that have since been written again - 409' {
        $read = TcVersion $script:rp 'target-advice.json'
        New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') | Out-Null
        (TcVersion $script:rp 'target-advice.json') | Should -Not -Be $read -Because 'writing the options again gives them a new version'
        { Set-VmfTestTargetChoice -RunPath $script:rp -Choices @(@{ vmId = (TcId 'app-01'); option = 'v6' }) -Default 'current' `
                -ExpectedAdviceVersion $read -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = 't' } } |
            Should -Throw '409*changed since*'
    }

    It 'refuses to replace targets somebody else saved after this page read them' {
        TcSave $script:rp @(@{ vmId = (TcId 'app-01'); option = 'v6' }) | Out-Null
        { TcSave $script:rp @(@{ vmId = (TcId 'app-01'); option = 'v5' }) } | Should -Throw '409*saved the targets*'
        { TcSave $script:rp @(@{ vmId = (TcId 'app-01'); option = 'v5' }) -Previous (TcVersion $script:rp 'target-choices.json') } | Should -Not -Throw
    }

    It 'refuses options made by an older version, by name - 409' {
        # v1 named its defaults newest and smallest. A save against it would
        # read a default the file does not have.
        $file = Join-Path $script:rp 'target-advice.json'
        # SIZE-FIT-1 made the current version 3; the plant is any version before it.
        $old = (Get-Content $file -Raw) -replace '"schemaVersion": \d+', '"schemaVersion": 1'
        $old | Should -Match '"schemaVersion": 1' -Because 'the plant must land, or this proves nothing'
        Set-Content $file $old -NoNewline
        { Set-VmfTestTargetChoice -RunPath $script:rp -Choices @(@{ vmId = (TcId 'app-01'); option = 'v6' }) -Default 'current' `
                -ExpectedAdviceVersion (TcVersion $script:rp 'target-advice.json') -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = 't' } } |
            Should -Throw '409*older version*'
    }

    It 'refuses when the options have not been written yet' {
        Remove-Item (Join-Path $script:rp 'target-advice.json')
        { Set-VmfTestTargetChoice -RunPath $script:rp -Choices @(@{ vmId = (TcId 'app-01'); option = 'v6' }) -Default 'current' `
                -ExpectedAdviceVersion 'x' -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = 't' } } |
            Should -Throw '400*target options*not written*'
    }
}

Describe 'ADVISOR-1: the plan is built from each machine''s choice' {

    BeforeEach {
        $script:catalog = @((TcSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (TcSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (TcSku 'Standard_D2ds_v6'), (TcSku 'Standard_D2s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:rp = TcReviewed
        $script:mig = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-tcm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    }
    AfterEach {
        foreach ($d in $script:rp, $script:mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'a Generation 1 machine chosen for v5 is planned on v5 and lands in a wave, beside a machine on v6' {
        TcSave $script:rp @(@{ vmId = (TcId 'app-01'); option = 'v6' }, @{ vmId = (TcId 'legacy-01'); option = 'v5' }) | Out-Null
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig | Out-Null
        $plan = Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30
        $app = @($plan.entries) | Where-Object vmId -eq (TcId 'app-01')
        $legacy = @($plan.entries) | Where-Object vmId -eq (TcId 'legacy-01')
        $app.target.size | Should -Be 'Standard_D2ds_v6'
        $app.policy.targetGeneration | Should -Be 'v6'
        $legacy.target.size | Should -Be 'Standard_D2s_v5'
        $legacy.policy.targetGeneration | Should -Be 'v5'
        $legacy.path | Should -Be 'A'
        $legacy.wave | Should -Not -Be 'unscheduled' -Because 'GEN-V5-2: it used to be left out of every wave'
        $legacy.target.choice.option | Should -Be 'v5'
        $legacy.target.choice.chosenBy | Should -Be 'operator@example.com'
    }

    It 'AN-PLAN-1: a machine with accelerated networking off, planned on Intel D v5, has it turned on by the plan' {
        foreach ($d in $script:rp) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
        $script:rp = TcReviewed -AnOff @('legacy-01')
        TcSave $script:rp @(@{ vmId = (TcId 'app-01'); option = 'v6' }, @{ vmId = (TcId 'legacy-01'); option = 'v5' }) | Out-Null
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig | Out-Null
        $plan = Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30
        $legacy = @($plan.entries) | Where-Object vmId -eq (TcId 'legacy-01')
        $legacy.target.size | Should -Be 'Standard_D2s_v5'
        $legacy.policy.acceleratedNetworking | Should -Be 'ensureOn'
        $legacy.assessment.acceleratedNicCount | Should -Be 0 -Because 'carried, so a later series change decides the same way'
        (@($plan.entries) | Where-Object vmId -eq (TcId 'app-01')).policy.PSObject.Properties['acceleratedNetworking'] |
            Should -BeNullOrEmpty -Because 'v6 does not require it, and app-01 already has it on'
    }

    # MACHINE-PICK-1 rewrote the next two. These targets were saved with no list
    # of chosen machines - an assessment from before that change - so every
    # machine with a saved target counts as chosen, and a plan holds only the
    # chosen machines. A machine left out used to be in the plan as MANUAL with
    # "No target was chosen"; now it is not in the plan at all, and stays in
    # the assessment. A chosen machine with no target is still MANUAL with that
    # note, and a chosen blocked one keeps its real reason (MachineChoice.Tests.ps1).
    It 'a machine that could move but was left out is not moved: it has no entry in the plan' {
        TcSave $script:rp @(@{ vmId = (TcId 'legacy-01'); option = 'v5' }) | Out-Null
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig | Out-Null
        $plan = Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30
        @($plan.entries | ForEach-Object { $_.vmId }) | Should -Be @((TcId 'legacy-01'))
        @((Get-Content (Join-Path $script:mig 'assessment.json') -Raw | ConvertFrom-Json).vms.vmId) | Should -Contain (TcId 'app-01')
    }

    It 'a machine already on NVMe, with no target, is not in the plan' {
        TcSave $script:rp @(@{ vmId = (TcId 'app-01'); option = 'v6' }) | Out-Null
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig | Out-Null
        $plan = Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30
        @($plan.entries) | Where-Object vmId -eq (TcId 'new-09') | Should -BeNullOrEmpty
    }

    It 'the choices travel with the migration, as the assessment does' {
        TcSave $script:rp @(@{ vmId = (TcId 'app-01'); option = 'v6' }) | Out-Null
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig | Out-Null
        Test-Path (Join-Path $script:mig 'target-choices.json') | Should -BeTrue
    }

    It 'with no choices saved, every machine is planned on the series named, as before - and marked as the plan''s' {
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -TargetGeneration v6 | Out-Null
        $plan = Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30
        $app = @($plan.entries) | Where-Object vmId -eq (TcId 'app-01')
        $app.target.size | Should -Be 'Standard_D2ds_v6'
        $app.target.choice.source | Should -Be 'plan'
    }

    It 'refuses choices saved against a different scan of the machines' {
        TcSave $script:rp @(@{ vmId = (TcId 'app-01'); option = 'v6' }) | Out-Null
        $c = Get-Content (Join-Path $script:rp 'target-choices.json') -Raw | ConvertFrom-Json -Depth 20
        $c.assessmentHash = ('f' * 64)
        $c | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $script:rp 'target-choices.json')
        { New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig } |
            Should -Throw '*different scan*'
    }

    It 'every entry it writes matches the plan-entry schema, at version 15' {
        TcSave $script:rp @(@{ vmId = (TcId 'app-01'); option = 'v6' }, @{ vmId = (TcId 'legacy-01'); option = 'v5' }) | Out-Null
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig | Out-Null
        $plan = Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30
        foreach ($e in @($plan.entries)) {
            $e.schemaVersion | Should -Be (InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion })
            ($e | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') | Should -BeTrue
        }
    }
}

Describe 'ADVISOR-1: the app cannot plan without a target for each machine' {

    BeforeEach {
        $script:catalog = @((TcSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (TcSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (TcSku 'Standard_D2ds_v6'), (TcSku 'Standard_D2s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:rp = TcReviewed
        $script:mig = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-tcg-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    }
    AfterEach { foreach ($d in $script:rp, $script:mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } } }

    It 'the engine''s plan operation, with no targets saved, is refused and says what to do' {
        { New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets } |
            Should -Throw '*No target was chosen*Choose the target for each machine*'
        Test-Path (Join-Path $script:mig 'plan.json') | Should -BeFalse
    }

    It 'once targets are saved, it plans' {
        TcSave $script:rp @(@{ vmId = (TcId 'app-01'); option = 'v6' }) | Out-Null
        { New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets } | Should -Not -Throw
    }

    It 'the hosted engine asks for it unless the request named one series' {
        $entry = Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw
        $branch = [regex]::Match($entry, "(?s)'plan' \{(.*?)\n    \}").Groups[1].Value
        $branch | Should -Match 'else \{ \$planParams\.RequireTargets = \$true \}'
        $branch | Should -Match 'if \(\$env:VMF_TARGET_GENERATION\) \{ \$planParams\.TargetGeneration = \$env:VMF_TARGET_GENERATION \}'
    }

    It 'an assessment nobody reviewed is still refused for THAT first' {
        Remove-Item (Join-Path $script:rp 'approval.json')
        { New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets } |
            Should -Throw '*has not been reviewed*'
    }
}

Describe 'WAVE-SERIES-GONE-1: a wave cannot replace the machines'' choices' {
    It 'there is no command, no service route and no page control that changes a wave''s series' {
        Get-Command Set-VmfWaveGeneration -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        Test-Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostSetWaveGeneration') | Should -BeFalse
        $waves = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html'))
        $waves | Should -Not -Match 'data-genapply|data-gen='
    }
}
Describe 'ADVISOR-1: the service saves them for the signed-in user' {

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        function Global:TcPrincipal([string]$Role) {
            $claims = @(@{ typ = 'preferred_username'; val = 'person@example.com' }, @{ typ = 'roles'; val = $Role })
            $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
            ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
        }
    }
    AfterAll { Remove-Item 'function:\TcPrincipal' -ErrorAction SilentlyContinue }

    BeforeEach {
        $script:catalog = @((TcSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (TcSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (TcSku 'Standard_D2ds_v6'), (TcSku 'Standard_D2s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:rp = TcReviewed
        $script:args6 = @{ Default = 'current'; AdviceVersion = (TcVersion $script:rp 'target-advice.json'); ChoicesVersion = ''
            Choices = @([pscustomobject]@{ vmId = (TcId 'app-01'); option = 'v6' }) }
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'an operator saves; the identity is the signed-in user' {
        $a = $script:args6
        Invoke-VmfTestFacadeSetTargets -Principal (TcPrincipal 'Vmf.Operator') -StorePath $script:rp @a | Out-Null
        (Get-Content (Join-Path $script:rp 'target-choices.json') -Raw | ConvertFrom-Json).savedBy.identity | Should -Be 'person@example.com'
    }

    It 'a viewer may not' {
        $a = $script:args6
        { Invoke-VmfTestFacadeSetTargets -Principal (TcPrincipal 'Vmf.Viewer') -StorePath $script:rp @a } | Should -Throw '403*'
    }

    It 'stale options or a newer save come back as 409, a refused choice as 400' {
        $stale = @{} + $script:args6; $stale.AdviceVersion = 'old'
        { Invoke-VmfTestFacadeSetTargets -Principal (TcPrincipal 'Vmf.Operator') -StorePath $script:rp @stale } | Should -Throw '409*'
        $bad = @{} + $script:args6; $bad.Choices = @([pscustomobject]@{ vmId = (TcId 'legacy-01'); option = 'v6' })
        { Invoke-VmfTestFacadeSetTargets -Principal (TcPrincipal 'Vmf.Operator') -StorePath $script:rp @bad } | Should -Throw '400*'
    }

    It 'the route is POST assessments/{runId}/targets' {
        $fj = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostSetTargets' 'function.json') -Raw | ConvertFrom-Json
        $http = @($fj.bindings) | Where-Object type -eq 'httpTrigger'
        $http.route | Should -Be 'assessments/{runId}/targets'
        @($http.methods) | Should -Be @('post')
    }
}
