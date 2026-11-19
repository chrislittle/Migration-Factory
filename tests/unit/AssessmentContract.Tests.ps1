#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
CONTRACT-1: the assessment document has a schema, and it is CLOSED.

assessment.json is the most-read document in the product - New-VmfPlan builds
the plan from it, five dashboard pages draw from it, and the support bundle
carries it. It was the last significant document without a schema, while eleven
others had one. Even the APPROVAL of an assessment had one; the assessment did
not.

The failure that gap allows is recorded in ci.yml, about the dashboard:

    "the function deciding whether any assessment appears in the app had no
     tests at all, which is how 'I see no assessments in the portal' happened."

A writer and a reader disagreeing about a field is exactly that, and nothing
structural prevented it.

THE SCHEMA WAS WRITTEN FROM THE WRITER, NOT DESIGNED. Every field was read out
of Invoke-VmfAssessment and Get-VmfAssessmentRecord, and the test below
GENERATES a real record and validates that - so the schema cannot drift from
the code while the sample keeps passing. A schema that does not match today's
document is worse than none, because it makes the contract tests lie.
#>
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:schemaFile = Join-Path $script:repoRoot 'schemas' 'assessment.schema.json'
    $script:sampleFile = Join-Path $script:repoRoot 'schemas' 'samples' 'assessment.sample.json'

    function Global:Test-VmfAssessmentJson {
        param([Parameter(Mandatory)][string]$Json)
        # SWAP-REFUSED-AFTER-STOP-1: Test-Json returns False, and does not throw, for a
        # fault inside a nested list (measured on PowerShell 7.6.7, 2026-10-23). A False
        # is a refusal too.
        $valid = Test-Json -Json $Json -SchemaFile $script:schemaFile -ErrorAction Stop
        if (-not $valid) { throw 'The JSON is not valid with the schema.' }
        $valid
    }

    # A machine record straight out of the code that writes them. Pure - it
    # takes an object and returns one, with no Azure in it, which is what makes
    # this checkable at all.
    function Global:New-VmfTestRecord {
        param([hashtable]$Overrides = @{})
        $vm = [pscustomobject]@{
            id = '/subscriptions/aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-web-01'
            name = 'app-web-01'; resourceGroup = 'rg-app'; location = 'eastus'
            zones = @('1'); sku = 'Standard_D2ds_v4'; os = 'Windows'
            imagePublisher = 'MicrosoftWindowsServer'; imageOffer = 'WindowsServer'
            imageSku = '2022-datacenter-smalldisk-g2'; imageId = ''
            diskController = 'SCSI'; securityType = 'TrustedLaunch'
            dataDiskCount = 2; nicCount = 3; hasManagedOsDisk = $true
            availabilitySetId = ''; tags = [pscustomobject]@{ app = 'payments' }
            hyperVGeneration = 'V2'
        }
        foreach ($k in $Overrides.Keys) {
            $vm | Add-Member -NotePropertyName $k -NotePropertyValue $Overrides[$k] -Force
        }
        & (Get-Module VmMigrationFactory) {
            param($v)
            Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -AppGroupTag 'app' `
                -ImageNvmeSupported $true -NicAcceleratedMap @{} `
                -AvdSessionHosts @{} -ManagedPlatformGroups @{}
        } $vm
    }

    function Global:New-VmfTestAssessment {
        param($Records)
        [ordered]@{
            schemaVersion = (& (Get-Module VmMigrationFactory) { Get-VmfAssessmentSchemaVersion })
            runId = 'assessment-2026-09-14-a1b2c3'
            generatedUtc = '2026-09-14T09:15:00.0000000Z'
            scope = [ordered]@{
                subscriptions = @('aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e')
                managementGroup = $null; tagFilter = $null
                resourceGroups = @('rg-app')
            }
            summary = [ordered]@{ ReadyAfterPrep = 1 }
            notRead = @()
            vms = @($Records)
        }
    }
}

AfterAll {
    foreach ($f in 'Test-VmfAssessmentJson', 'New-VmfTestRecord', 'New-VmfTestAssessment') {
        Remove-Item "function:\$f" -ErrorAction SilentlyContinue
    }
}

Describe 'CONTRACT-1: the assessment document validates against its schema' {

    It 'the schema and the sample both exist' {
        Test-Path $script:schemaFile | Should -BeTrue
        Test-Path $script:sampleFile | Should -BeTrue
    }

    It 'the sample validates' {
        { Test-VmfAssessmentJson -Json (Get-Content $script:sampleFile -Raw) } | Should -Not -Throw
    }

    It 'A RECORD THE CODE ACTUALLY WRITES validates - the schema tracks the writer' {
        <#
            The assertion that matters. The sample is a file somebody can edit
            to keep green; this generates the record from Get-VmfAssessmentRecord
            itself. Add a field to that function without declaring it here and
            this fails, which is the whole point of closing the schema: the next
            addition becomes deliberate rather than silent.
        #>
        $doc = New-VmfTestAssessment -Records (New-VmfTestRecord)
        { Test-VmfAssessmentJson -Json ($doc | ConvertTo-Json -Depth 8) } | Should -Not -Throw
    }

    It 'and a REGIONAL machine (no availability zone), as Resource Graph returns it, validates too' {
        # AN-PRIMARY-1 found it: the record above is ZONAL. A regional machine
        # arrives with zones = null, which every real scan wrote as
        # "zones": [null], against this schema, while this test stayed green.
        $rec = New-VmfTestRecord -Overrides @{ zones = $null }
        @($rec.zones).Count | Should -Be 0
        $doc = New-VmfTestAssessment -Records $rec
        { Test-VmfAssessmentJson -Json ($doc | ConvertTo-Json -Depth 8) } | Should -Not -Throw
    }

    It 'every classification the code can produce is one the schema allows' {
        # The verdicts are an enum in the schema and a set of branches in
        # Rules.ps1. Two lists that must agree, so they are compared rather
        # than trusted.
        $schema = Get-Content $script:schemaFile -Raw | ConvertFrom-Json
        $allowed = @($schema.properties.vms.items.properties.classification.enum)
        $allowed | Should -Not -Contain 'ReadyNow' -Because 'OLD-VERSION-READERS-REMOVE-2: no reader takes it'
        $allowed | Should -Contain 'ReadyAfterPrep'
        $allowed | Should -Contain 'Blocked'
        $allowed | Should -Contain 'Excluded'

        # Only the values ASSIGNED - the literals inside the branch braces.
        # A looser scrape of the same block picked up 'NVMe' from the
        # comparison on the next line and reported a classification the code
        # cannot produce. The test was wrong, not the code, which is the usual
        # way round for a check that reads source.
        $rules = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Rules.ps1') -Raw
        # The pattern carries NO backslash escape a shell knows. Written with
        # \n this arrived containing real newlines and matched by accident -
        # the exact failure CLAUDE.md records. It ends at the else branch,
        # which is the last thing the chain assigns.
        $block = [regex]::Match($rules, "(?s)\`$classification =.*?else \{ '[A-Za-z]+' \}").Value
        $block | Should -Not -BeNullOrEmpty -Because 'the classification block must be found to be checked'
        $produced = @([regex]::Matches($block, "\{\s*'(?<c>[A-Za-z]+)'\s*\}") |
            ForEach-Object { $_.Groups['c'].Value } | Sort-Object -Unique)
        # READY-NOW-REMOVE-1: three - the scan writes no ReadyNow (assessment v11).
        $produced.Count | Should -Be 3 -Because 'three verdicts, and the scrape must find all of them'
        $produced | Should -Not -Contain 'ReadyNow'
        foreach ($c in $produced) {
            $allowed | Should -Contain $c -Because "Rules.ps1 can classify a machine as '$c'"
        }
    }
}

Describe 'CONTRACT-1: the schema is CLOSED, and that is what it is for' {

    It 'GUARD THE GUARD: an undeclared field is REJECTED' {
        <#
            If Test-Json ignored additionalProperties, every test in this file
            would pass while the schema checked nothing - which is the shape of
            the vm-state schema's own lesson, recorded in StateContract.

            This is also the assertion the strict-schema decision rests on: strict
            means an unexpected field is an error, and here is the proof it is.
        #>
        $doc = New-VmfTestAssessment -Records (New-VmfTestRecord)
        $doc.vms = @($doc.vms | ForEach-Object {
            $_ | Add-Member -NotePropertyName 'somethingNobodyDeclared' -NotePropertyValue 1 -PassThru
        })
        { Test-VmfAssessmentJson -Json ($doc | ConvertTo-Json -Depth 8) } |
            Should -Throw -Because 'a field the schema does not know about is how a reader silently finds nothing'
    }

    It 'an undeclared field at the TOP level is rejected too' {
        $doc = New-VmfTestAssessment -Records (New-VmfTestRecord)
        $doc['totallyNewSection'] = @{ a = 1 }
        { Test-VmfAssessmentJson -Json ($doc | ConvertTo-Json -Depth 8) } | Should -Throw
    }

    It 'a verdict nothing else in the product knows about is rejected' {
        $doc = New-VmfTestAssessment -Records (New-VmfTestRecord)
        $doc.vms[0].classification = 'ProbablyFine'
        { Test-VmfAssessmentJson -Json ($doc | ConvertTo-Json -Depth 8) } | Should -Throw
    }
}

Describe 'CONTRACT-1: only an assessment of the current version is valid' {

    It 'an assessment of an earlier version is not valid' {
        <#
            OLD-VERSION-READERS-REMOVE-1 (2026-11-11: no installation runs an
            earlier version): nothing is public before 1.0, so no store holds an
            assessment of an earlier version, and Assert-VmfSupportedAssessment
            takes only the current one. The schema says the same.
        #>
        $old = [ordered]@{
            schemaVersion = 1
            runId = 'assessment-2026-08-01-old'
            generatedUtc = '2026-08-01T00:00:00.0000000Z'
            scope = [ordered]@{ subscriptions = @('aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e') }
            summary = [ordered]@{ ReadyNow = 1 }
            vms = @(
                [ordered]@{
                    vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/old'
                    name = 'old'; resourceGroup = 'rg'; location = 'eastus'
                    classification = 'ReadyNow'; sourceSize = 'Standard_D2s_v5'
                }
            )
        }
        { Test-VmfAssessmentJson -Json ($old | ConvertTo-Json -Depth 8) } |
            Should -Throw -Because 'no reader of this build takes an assessment of version 1'
    }

    It 'but a record with no machine id is NOT valid' {
        # The floor. A record that cannot say which machine it is about is not
        # an old record, it is a broken one.
        $doc = New-VmfTestAssessment -Records (New-VmfTestRecord)
        $doc.vms[0].PSObject.Properties.Remove('vmId')
        { Test-VmfAssessmentJson -Json ($doc | ConvertTo-Json -Depth 8) } | Should -Throw
    }

    It 'the nullable fields really are allowed to be null' {
        # gen, sourceTempDisks, acceleratedNicCount and appGroup are null when
        # the catalog could not say. "Unknown must never be read as a pass" is
        # a rule this product states repeatedly; a schema that refused null
        # would push the writer into inventing a value.
        $doc = New-VmfTestAssessment -Records (New-VmfTestRecord)
        foreach ($f in 'gen', 'sourceTempDisks', 'acceleratedNicCount', 'appGroup') {
            $doc.vms[0].$f = $null
        }
        { Test-VmfAssessmentJson -Json ($doc | ConvertTo-Json -Depth 8) } | Should -Not -Throw
    }
}
