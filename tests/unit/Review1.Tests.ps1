#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# REVIEW-1: what the review of 2026-09-26's changes found in the engine and the
# service, each fixed the way the product already does the same thing.
#
# Before any more of ADVISOR-1 could ship, a full review of everything that
# worked before had to prove the new work matches it, with no major
# regression. Two independent reviews
# compared every change of the day with the product's own patterns.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    function Global:R1Sku([string]$Name, [string]$TempMb = '0', [string]$Gens = 'V2') {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
    }
    function Global:R1Vm([int]$Nics = 1, [object]$AnCount = 1) {
        [pscustomobject]@{
            vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/m'
            name = 'm'; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; osVersion = '22_04-lts-gen2'
            sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = 'SCSI'
            dataDiskCount = 1; nicCount = $Nics; acceleratedNicCount = $AnCount; platformManaged = $false; blockers = @(); prepNeeded = @()
        }
    }
    function Global:R1V5Option($vm) {
        $cat = @{}
        foreach ($s in @((R1Sku 'Standard_D2ds_v5' '76800' 'V1,V2'), (R1Sku 'Standard_D2ds_v6'))) { $cat[$s.Name] = $s }
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'r'; vms = @($vm) }
        $a = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = $cat } { Get-VmfTargetAdvice -Assessment $d -CatalogByLocation @{ centralus = $c } }
        @(@($a.machines)[0].options) | Where-Object { $_.option -eq 'v5' }
    }
}
AfterAll { Remove-Item 'function:\R1Sku', 'function:\R1Vm', 'function:\R1V5Option' -ErrorAction SilentlyContinue }

Describe 'REVIEW-1: accelerated networking is predicted only where the engine''s rule can be followed' {
    # The engine stops for the PRIMARY interface (Resolve-VmfAcceleratedNetworkingForMove).
    # The scan records how many interfaces have it on.

    It 'one interface with it on: no stop' {
        $o = R1V5Option (R1Vm -Nics 1 -AnCount 1)
        $o.acceleratedNetworking.turnsOn | Should -BeFalse
        @($o.stops).Count | Should -Be 0
    }

    It 'none on, however many interfaces: the stop is certain' {
        $o = R1V5Option (R1Vm -Nics 3 -AnCount 0)
        $o.acceleratedNetworking.turnsOn | Should -BeTrue
        @($o.stops) | Should -Contain 'acceleratedNetworkingRequired'
    }

    It 'several interfaces with some on: unknown - the primary may be the one that is off' {
        $o = R1V5Option (R1Vm -Nics 2 -AnCount 1)
        $null -eq $o.acceleratedNetworking.turnsOn | Should -BeTrue
        @($o.stops).Count | Should -Be 0 -Because 'no stop is promised or ruled out'
    }
}

Describe 'REVIEW-1: a failed start of the target options is written to the run' {

    BeforeAll {
        function Global:R1Approver {
            $claims = @(@{ typ = 'preferred_username'; val = 'person@example.com' }, @{ typ = 'roles'; val = 'Vmf.Approver' })
            $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
            ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
        }
    }
    AfterAll { Remove-Item 'function:\R1Approver' -ErrorAction SilentlyContinue }

    It 'under the step the engine''s own refusals use, so the pages that show engine failures show it' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-r1-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ p = $rp; d = ([ordered]@{ schemaVersion = 17; runId = 'scan-1'; vms = @(R1Vm) }) } {
                Initialize-VmfRun -RunPath $p -RunId 'scan-1' -Kind 'assessment' | Out-Null
                Write-VmfStoreJson -RunPath $p -RelPath 'assessment.json' -Document $d -Depth 24
            }
            Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { throw 'the engine job could not be read' }
            Invoke-VmfFacadeApproveAssessment -Principal (R1Approver) -StorePath $rp -AssessmentHash (InModuleScope VmMigrationFactory -Parameters @{ p = $rp } { param($p) Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $p -RelPath 'assessment.json')) }) -RunId 'scan-1' | Out-Null
            $events = @(Get-Content (Join-Path $rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
            $e = $events | Where-Object { $_.step -eq 'engine:advise' -and $_.outcome -eq 'fail' }
            $e | Should -Not -BeNullOrEmpty
            $e.detail | Should -Match 'did not start'
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }

    It 'and an advise start names an ASSESSMENT run, as assess and plan do' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $code | Should -Match "\`$auditKind = if \(\`$Operation -in @\('assess', 'plan', 'advise'\)\)"
    }
}

Describe 'REVIEW-1: the options for a run with no scan say so' {

    It 'instead of an unsupported-version or cannot-find-path error' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-r1-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ p = $rp } { Initialize-VmfRun -RunPath $p -RunId 'scan-1' -Kind 'assessment' | Out-Null }
            { New-VmfTargetAdvice -AssessmentPath (Join-Path $rp 'assessment.json') } | Should -Throw '*has not finished scanning*'
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }

    It 'the approval and the options hash the assessment with the one shared function' {
        foreach ($f in 'Approve-VmfAssessment.ps1', 'New-VmfTargetAdvice.ps1') {
            $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' $f)
            $code | Should -Match 'Get-VmfDocumentVersion -Text' -Because $f
            $code | Should -Not -Match 'SHA256' -Because "$f must not keep its own copy"
        }
    }
}

Describe 'REVIEW-1: a v5 refusal says v5' {

    It 'a family with no v5 size in the region is told about v5, not v6 or v7' {
        InModuleScope VmMigrationFactory -Parameters @{ c = @{ 'Standard_D2ds_v5' = (R1Sku 'Standard_D2ds_v5' '76800' 'V1,V2') } } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_L8s_v3' -CatalogBySize $c -TargetGeneration 'v5'
            $r.Code | Should -Be 'family-not-in-region'
            $r.Reason | Should -Match 'no v5 size'
            $r.Reason | Should -Not -Match 'v6'
        }
    }

    It 'and a v6 refusal is worded as it always was' {
        InModuleScope VmMigrationFactory -Parameters @{ c = @{ 'Standard_D2ds_v6' = (R1Sku 'Standard_D2ds_v6') } } {
            (Get-VmfTargetSize -SourceSize 'Standard_L8s_v3' -CatalogBySize $c -TargetGeneration 'v6').Reason |
                Should -Match 'not part of the v6/v7 migration path'
        }
    }
}

# REPORT-AUTO-1 MOVED this judgement from the report's engineering appendix
# into the migration record (machines[].assessment), when the report became
# one kind. Same rule, same machine; the place a person reads it changed.
Describe 'REVIEW-1: the record judges a planned machine against its series' {

    It 'a Generation 1 machine in a v5 wave is not reported as blocked' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-r1-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            $id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/legacy-01'
            $vm = [ordered]@{ vmId = $id; name = 'legacy-01'; classification = 'Blocked'; gen = 'V1'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'
                sourceDiskArch = 'diskless'; diskController = ''; blockers = @('gen1-requires-redeploy'); prepNeeded = @(); platformManaged = $false }
            $entry = [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'wave-1'; appGroup = 'legacy-01'
                assessment = [ordered]@{ classification = 'Blocked'; gen = 'V1'; os = 'Linux'; sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'
                    location = 'centralus'; blockers = @('gen1-requires-redeploy'); prepNeeded = @(); platformManaged = $false; dataDiskCount = 0; nicCount = 1; availabilitySetId = '' }
                target = [ordered]@{ size = 'Standard_D2s_v5'; sizeAlternates = @(); diskArch = 'diskless'; tempDisks = 0; controller = 'SCSI'; zone = $null }
                path = 'A'; policy = [ordered]@{ targetGeneration = 'v5'; requireApproval = $true }; planNotes = @() }
            InModuleScope VmMigrationFactory -Parameters @{ p = $rp; a = ([ordered]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($vm); summary = @{} }); e = $entry } {
                Initialize-VmfRun -RunPath $p -RunId (Split-Path $p -Leaf) -Kind 'migration' | Out-Null
                Write-VmfStoreJson -RunPath $p -RelPath 'assessment.json' -Document $a -Depth 24
                Write-VmfStoreJson -RunPath $p -RelPath 'plan.json' -Document ([ordered]@{ schemaVersion = 4; entries = @($e) }) -Depth 24
            }
            $rec = InModuleScope VmMigrationFactory -Parameters @{ p = $rp } { param($p) Get-VmfMigrationRecordFromStore -RunPath $p -Reason 'downloaded' }
            $m = @($rec.machines | Where-Object { $_.name -eq 'legacy-01' })[0]
            $m.assessment | Should -Not -BeNullOrEmpty
            $m.assessment.classification | Should -Not -Be 'Blocked'
            @($m.assessment.issues) | Should -Not -Contain 'gen1-requires-redeploy'
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }
}
