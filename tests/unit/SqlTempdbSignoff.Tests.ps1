#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
SQL-TEMPDB-SIGNOFF-1 (2026-11-16): the plan sign-off names each
machine where the scan found SQL Server and whose move takes it from a SCSI
temporary disk to an NVMe temporary disk or to none, and asks the approver to
confirm that they checked where tempdb is.

Microsoft, "Fix SQL Server on Azure VM deployment and startup failures": on a
size with a raw NVMe local disk, SQL Server fails to come online when tempdb is
on that disk. A size with no temporary disk has no D: at all.

The rule: ONLY where the scan detects SQL Server. So:
  - SQL Server found = the scan's own finding (warning sql-server-agree-downtime,
    from the SQL VM resource read or a SQL Server image). No new check inside a
    machine, no new Azure read, no new permission.
  - The risk = a machine that moves (path A), from a SCSI temporary disk
    (assessment.sourceDiskArch scsi-temp) to an NVMe temporary disk or none
    (target.diskArch nvme-temp or diskless, Get-VmfDiskArchitecture).
  - A machine with no SQL Server finding gets nothing, whatever its target. A
    SQL Server machine whose target keeps a SCSI temporary disk (a v5 d size)
    gets nothing.
  - The sign-off is refused until the approver names every such machine, and
    the record names them (plan-approval v4 sqlTempdbChecked). A wave approval
    on its own is refused for a wave with such a machine the sign-off does not
    name - else a target changed after the sign-off would get past the box.
#>
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function script:StId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-db/providers/Microsoft.Compute/virtualMachines/$Name" }
    # One plan entry. Defaults: a SQL Server machine on a SCSI temporary disk,
    # moving to an NVMe temporary disk - the case.
    function script:StEntry([string]$Name, [string]$Wave = 'w1', $Sql = $true, [string]$From = 'scsi-temp', [string]$To = 'nvme-temp', [string]$Path = 'A') {
        $a = [ordered]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Windows'; sourceSize = 'Standard_E2ds_v5'; sourceDiskArch = $From }
        if ($null -ne $Sql) { $a.sqlServerDetected = $Sql }
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = (StId $Name); wave = $Wave; path = $Path
            assessment = [pscustomobject]$a
            target = [pscustomobject]@{ size = 'Standard_E2ds_v6'; diskArch = $To; controller = $(if ($To -eq 'scsi-temp') { 'SCSI' } else { 'NVMe' }) }
            policy = [pscustomobject]@{ throttle = 5 } }
    }
    function script:StRisk($Entry) { InModuleScope VmMigrationFactory -Parameters @{ e = $Entry } { Test-VmfSqlTempdbRisk -Entry $e } }
    function script:StPlan([object[]]$Entries) {
        $run = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sqlts-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $run -Force | Out-Null
        [pscustomobject]@{ assessmentRunId = 'r1'; entries = @($Entries) } | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $run 'plan.json')
        $run
    }
    $script:who = @{ Identity = 'approver@example.com'; TenantId = $null }
}

Describe 'SQL-TEMPDB-SIGNOFF-1: the rule' {
    It 'THE CASE: SQL Server found, a SCSI temporary disk now, an NVMe temporary disk or none after the move' {
        StRisk (StEntry 'sql-01') | Should -BeTrue
        StRisk (StEntry 'sql-02' -To 'diskless') | Should -BeTrue
    }

    It 'RULE: no SQL Server found gets nothing, whatever the target' {
        StRisk (StEntry 'app-01' -Sql $false) | Should -BeFalse
        StRisk (StEntry 'app-02' -Sql $false -To 'diskless') | Should -BeFalse
        StRisk (StEntry 'app-03' -Sql $null) | Should -BeFalse -Because 'a field that is not there is not a finding'
        StRisk (StEntry 'app-04' -Sql 'true') | Should -BeFalse -Because 'only a stored true is a finding'
    }

    It 'RULE: SQL Server found and a target that keeps a SCSI temporary disk (a v5 d size) gets nothing' {
        StRisk (StEntry 'sql-v5' -To 'scsi-temp') | Should -BeFalse
    }

    It 'a machine whose D: has no SCSI temporary disk now is not changed by the move' {
        StRisk (StEntry 'sql-none' -From 'diskless') | Should -BeFalse
        StRisk (StEntry 'sql-nvme' -From 'nvme-temp') | Should -BeFalse
    }

    It 'only a machine that moves counts' {
        StRisk (StEntry 'sql-man' -Path 'MANUAL') | Should -BeFalse
        StRisk (StEntry 'sql-exc' -Path 'EXCLUDED') | Should -BeFalse
        StRisk $null | Should -BeFalse
    }

    It 'every case of the shared table (the page reads the same file)' {
        $table = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'sql-tempdb-risk.json') -Raw | ConvertFrom-Json -Depth 10
        @($table.cases).Count | Should -BeGreaterThan 10
        foreach ($c in @($table.cases)) {
            StRisk $c.entry | Should -Be ([bool]$c.risk) -Because $c.name
        }
    }

    It 'the list for a plan, and for one wave' {
        $all = @((StEntry 'sql-01'), (StEntry 'app-01' -Sql $false), (StEntry 'sql-02' -Wave 'w2' -To 'diskless'), (StEntry 'sql-v5' -To 'scsi-temp'))
        $ids = InModuleScope VmMigrationFactory -Parameters @{ a = $all } { @(Get-VmfSqlTempdbRiskEntries -Entries $a) | ForEach-Object vmId }
        @($ids) | Should -Be @((StId 'sql-01'), (StId 'sql-02'))
        $w2 = InModuleScope VmMigrationFactory -Parameters @{ a = $all } { @(Get-VmfSqlTempdbRiskEntries -Entries $a -Wave 'w2') | ForEach-Object vmId }
        @($w2) | Should -Be @((StId 'sql-02'))
    }

    It 'the finding is the scan''s own warning - no new check, no new Azure read' {
        InModuleScope VmMigrationFactory {
            Test-VmfSqlServerFound -Vm ([pscustomobject]@{ warnings = @('sql-server-agree-downtime') }) | Should -BeTrue
            Test-VmfSqlServerFound -Vm ([pscustomobject]@{ warnings = @('os-disk-standard-hdd') }) | Should -BeFalse
            Test-VmfSqlServerFound -Vm ([pscustomobject]@{ warnings = @() }) | Should -BeFalse
            Test-VmfSqlServerFound -Vm ([pscustomobject]@{ }) | Should -BeFalse
            Test-VmfSqlServerFound -Vm $null | Should -BeFalse
        }
        # The code the scan writes for SQL Server (Rules.ps1) is the one read.
        $rules = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Rules.ps1')
        $rules | Should -Match "warnings\.Add\('sql-server-agree-downtime'\)"
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'SqlTempdbRisk.ps1')
        $code | Should -Not -Match 'Invoke-Vmf(Az|Arm)|Get-Az|RunCommand' -Because 'the rule: no new Azure read and no check inside a machine'
    }
}

Describe 'SQL-TEMPDB-SIGNOFF-1: the plan entry carries the finding (plan-entry v37)' {
    It 'the schema, the module, the sample and the migration note agree' {
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json -Depth 50
        $s.properties.schemaVersion.const | Should -Be 37
        $s.properties.schemaVersion.description | Should -Match '^37 \(SQL-TEMPDB-SIGNOFF-1'
        @($s.properties.assessment.properties.sqlServerDetected.type) | Should -Be @('boolean')
        InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion | Should -Be 37 }
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json') -Raw
        ($sample | ConvertFrom-Json).schemaVersion | Should -Be 37
        $sample | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') | Should -BeTrue
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match '## plan-entry v36 -> v37 and plan-approval v3 -> v4 \(2026-11-16, SQL-TEMPDB-SIGNOFF-1\)'
    }

    It 'New-VmfPlan writes it from the scan''s warning, true and false' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfPlan.ps1')
        $code | Should -Match 'sqlServerDetected = Test-VmfSqlServerFound -Vm \$p\.vm'
    }

    It 'a target changed for one machine keeps the finding (the assessment block is kept)' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Set-VmfMachineTarget.ps1')
        $code | Should -Not -Match '\$entry\.assessment\s*='
    }
}

Describe 'SQL-TEMPDB-SIGNOFF-1: New-VmfPlan from a real assessment' {
    BeforeAll {
        function script:StSku([string]$Name, [double]$Vcpus, [double]$MemoryGB, [string]$TempMb = '0', [string]$Gens = 'V1,V2') {
            [pscustomobject]@{ Name = $Name; Family = 'x'; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = @(
                    [pscustomobject]@{ Name = 'vCPUs'; Value = [string]$Vcpus }
                    [pscustomobject]@{ Name = 'MemoryGB'; Value = [string]$MemoryGB }
                    [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                    [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }
                    [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                    [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '32' }
                    [pscustomobject]@{ Name = 'PremiumIO'; Value = 'True' }) }
        }
    }
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog {
            @((StSku 'Standard_E2ds_v4' 2 16 '76800'), (StSku 'Standard_E2ds_v5' 2 16 '76800'), (StSku 'Standard_E2s_v5' 2 16 '0'),
              (StSku 'Standard_E2ds_v6' 2 16 '0' 'V2'), (StSku 'Standard_E2s_v6' 2 16 '0' 'V2'), (StSku 'Standard_E2ads_v7' 2 16 '0' 'V2'),
              (StSku 'Standard_E2ds_v7' 2 16 '0' 'V2'), (StSku 'Standard_E2s_v7' 2 16 '0' 'V2'))
        }
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sqlta-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:mig = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sqltm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $base = [ordered]@{ vmId = (StId 'sql-01'); name = 'sql-01'; resourceGroup = 'rg-db'; location = 'centralus'; zones = @()
            classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; osVersion = '22.04-LTS'; sourceSize = 'Standard_E2ds_v4'
            sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = 'SCSI'; dataDiskCount = 0; nicCount = 1; acceleratedNicCount = 0
            platformManaged = $false; iacManaged = $false; availabilitySetId = ''; identityType = 'None'
            tags = @{ app = 'db' }; blockers = @(); prepNeeded = @(); warnings = @('sql-server-agree-downtime'); osDiskType = 'Premium_LRS' }
        $app = [ordered]@{} + $base
        $app.vmId = (StId 'app-01'); $app.name = 'app-01'; $app.warnings = @(); $app.tags = @{ app = 'app' }
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $script:rp -Leaf); generatedUtc = '2026-11-16T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}; vms = @($base, $app) }
        InModuleScope VmMigrationFactory -Parameters @{ p0 = $script:rp; d = $doc } {
            Initialize-VmfRun -RunPath $p0 -RunId (Split-Path $p0 -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $p0 -RelPath 'assessment.json' -Document $d -Depth 24
        }
        Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
    }
    AfterEach { foreach ($d in $script:rp, $script:mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } } }

    It 'the SQL Server machine is true, the other false, and each entry matches the contract' {
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig | Out-Null
        $entries = @((Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries)
        $sql = $entries | Where-Object vmId -EQ (StId 'sql-01')
        $app = $entries | Where-Object vmId -EQ (StId 'app-01')
        $sql.assessment.sqlServerDetected | Should -BeTrue
        $app.assessment.sqlServerDetected | Should -BeFalse
        $app.assessment.PSObject.Properties['sqlServerDetected'] | Should -Not -BeNullOrEmpty -Because 'false is written, not left out'
        foreach ($e in $entries) {
            $e.schemaVersion | Should -Be 37
            ($e | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') | Should -BeTrue
        }
    }
}

Describe 'SQL-TEMPDB-SIGNOFF-1: the plan sign-off' {
    AfterEach { if ($script:run -and (Test-Path $script:run)) { Remove-Item $script:run -Recurse -Force } }

    It 'THE CASE: refused until every such machine is named, and nothing is written' {
        $script:run = StPlan @((StEntry 'sql-01'), (StEntry 'sql-02' -To 'diskless'), (StEntry 'app-01' -Sql $false))
        { Approve-VmfPlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Note 'reviewed' -OnBehalfOf $script:who } |
            Should -Throw '400: SQL Server runs on sql-01, sql-02.*'
        { Approve-VmfPlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Note 'reviewed' -OnBehalfOf $script:who -SqlTempdbChecked @((StId 'sql-01')) } |
            Should -Throw '400: SQL Server runs on sql-02.*'
        Test-Path (Join-Path $script:run 'plan-approval.json') | Should -BeFalse
        Test-Path (Join-Path $script:run 'approvals') | Should -BeFalse -Because 'no wave approval either'
    }

    It 'with every machine named, it signs, and the record names them and matches the contract' {
        $script:run = StPlan @((StEntry 'sql-01'), (StEntry 'sql-02' -To 'diskless' -Wave 'w2'), (StEntry 'app-01' -Sql $false))
        # Case does not matter in a machine id, as in Azure.
        Approve-VmfPlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Note 'reviewed' -OnBehalfOf $script:who `
            -SqlTempdbChecked @((StId 'sql-01').ToUpperInvariant(), (StId 'sql-02')) | Out-Null
        $raw = Get-Content (Join-Path $script:run 'plan-approval.json') -Raw
        $raw | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-approval.schema.json') | Should -BeTrue
        $pa = $raw | ConvertFrom-Json
        $pa.schemaVersion | Should -Be 4
        @($pa.sqlTempdbChecked) | Should -Be @((StId 'sql-01'), (StId 'sql-02')) -Because 'the machines of the plan, in its spelling'
    }

    It 'RULE (1): no SQL Server found and an NVMe target - nothing asked, nothing recorded' {
        $script:run = StPlan @((StEntry 'app-01' -Sql $false), (StEntry 'app-02' -Sql $false -To 'diskless'))
        Approve-VmfPlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Note 'reviewed' -OnBehalfOf $script:who | Out-Null
        $pa = Get-Content (Join-Path $script:run 'plan-approval.json') -Raw | ConvertFrom-Json
        $pa.PSObject.Properties['sqlTempdbChecked'] | Should -BeNullOrEmpty
    }

    It 'RULE (2): SQL Server found and a SCSI temporary disk target (v5 d) - nothing asked, nothing recorded' {
        $script:run = StPlan @((StEntry 'sql-v5' -To 'scsi-temp'))
        Approve-VmfPlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Note 'reviewed' -OnBehalfOf $script:who | Out-Null
        $pa = Get-Content (Join-Path $script:run 'plan-approval.json') -Raw | ConvertFrom-Json
        $pa.PSObject.Properties['sqlTempdbChecked'] | Should -BeNullOrEmpty
    }

    It 'a name of a machine that is not at risk is not recorded' {
        $script:run = StPlan @((StEntry 'sql-01'), (StEntry 'app-01' -Sql $false))
        Approve-VmfPlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Note 'reviewed' -OnBehalfOf $script:who `
            -SqlTempdbChecked @((StId 'sql-01'), (StId 'app-01')) | Out-Null
        @((Get-Content (Join-Path $script:run 'plan-approval.json') -Raw | ConvertFrom-Json).sqlTempdbChecked) | Should -Be @((StId 'sql-01'))
    }

    It 'a changed plan is still a 409 first - the approver looks again' {
        $script:run = StPlan @((StEntry 'sql-01'))
        { Approve-VmfPlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Note 'n' -OnBehalfOf $script:who -ExpectedPlanHash ('0' * 64) } |
            Should -Throw '409:*'
    }
}

Describe 'SQL-TEMPDB-SIGNOFF-1: a wave approval on its own' {
    AfterEach { if ($script:run -and (Test-Path $script:run)) { Remove-Item $script:run -Recurse -Force } }

    It 'refused for a wave with such a machine that no sign-off names' {
        $script:run = StPlan @((StEntry 'sql-01'), (StEntry 'app-01' -Sql $false -Wave 'w2'))
        { Approve-VmfWave -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Wave 'w1' -Note 'n' -OnBehalfOf $script:who } |
            Should -Throw '400: SQL Server runs on sql-01 in wave w1.*'
        Test-Path (Join-Path $script:run 'approvals' 'w1.json') | Should -BeFalse
        # RULE: the wave with no SQL Server machine is approved as before.
        Approve-VmfWave -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Wave 'w2' -Note 'n' -OnBehalfOf $script:who | Out-Null
        Test-Path (Join-Path $script:run 'approvals' 'w2.json') | Should -BeTrue
    }

    It 'passes when the plan sign-off named the machine - also after its target changed to another such size' {
        $script:run = StPlan @((StEntry 'sql-01'))
        Approve-VmfPlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Note 'reviewed' -OnBehalfOf $script:who -SqlTempdbChecked @((StId 'sql-01')) | Out-Null
        $p = Get-Content (Join-Path $script:run 'plan.json') -Raw | ConvertFrom-Json -Depth 10
        $p.entries[0].target.diskArch = 'diskless'
        $p | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:run 'plan.json')
        Approve-VmfWave -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Wave 'w1' -Note 'n' -OnBehalfOf $script:who | Out-Null
        Test-Path (Join-Path $script:run 'approvals' 'w1.json') | Should -BeTrue
    }

    It 'refused when a target change after the sign-off makes a new such machine' {
        $script:run = StPlan @((StEntry 'sql-01' -To 'scsi-temp'))
        Approve-VmfPlan -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Note 'reviewed' -OnBehalfOf $script:who | Out-Null
        $p = Get-Content (Join-Path $script:run 'plan.json') -Raw | ConvertFrom-Json -Depth 10
        $p.entries[0].target.diskArch = 'nvme-temp'
        $p | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $script:run 'plan.json')
        { Approve-VmfWave -RunPath $script:run -PlanPath (Join-Path $script:run 'plan.json') -Wave 'w1' -Note 'n' -OnBehalfOf $script:who } |
            Should -Throw '400: SQL Server runs on sql-01 in wave w1.*'
    }
}

Describe 'SQL-TEMPDB-SIGNOFF-1: the service passes the names through' {
    BeforeEach {
        Mock -ModuleName FacadeCore Get-VmfFacadePlanPath { param($StorePath) Join-Path $StorePath 'plan.json' }
        $script:principal = [pscustomobject]@{ Identity = 'approver@example.com'; Roles = @('Vmf.Approver') }
    }
    AfterEach { if ($script:run -and (Test-Path $script:run)) { Remove-Item $script:run -Recurse -Force } }

    It 'Invoke-VmfFacadeApprovePlan gives the names to the sign-off' {
        $script:run = StPlan @((StEntry 'sql-01'))
        $hash = InModuleScope VmMigrationFactory -Parameters @{ f = (Join-Path $script:run 'plan.json') } { Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path $f) }
        { Invoke-VmfFacadeApprovePlan -Principal $script:principal -StorePath $script:run -Note 'n' -PlanHash $hash } | Should -Throw '400: SQL Server runs on sql-01*'
        Invoke-VmfFacadeApprovePlan -Principal $script:principal -StorePath $script:run -Note 'n' -PlanHash $hash -SqlTempdbChecked @((StId 'sql-01')) | Out-Null
        @((Get-Content (Join-Path $script:run 'plan-approval.json') -Raw | ConvertFrom-Json).sqlTempdbChecked) | Should -Be @((StId 'sql-01'))
    }

    It 'the endpoint reads sqlTempdbChecked from the body' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostApprovePlan' 'run.ps1')
        $code | Should -Match '-SqlTempdbChecked \$checked'
        $code | Should -Match '\$body\.sqlTempdbChecked'
    }
}

Describe 'SQL-TEMPDB-SIGNOFF-1: the report names the check in its Sign-off table' {
    It 'one decision: who signed off, when, and the machines' {
        $pa = [pscustomobject]@{ schemaVersion = 4; approvedBy = [pscustomobject]@{ identity = 'approver@example.com' }; approvedUtc = '2026-11-16T10:00:00Z'
            planHash = ('a' * 64); note = 'reviewed'; waves = @('w1'); sqlTempdbChecked = @((StId 'sql-01'), (StId 'sql-02')) }
        $rec = InModuleScope VmMigrationFactory -Parameters @{ pa = $pa } {
            ConvertTo-VmfMigrationRecord -Manifest ([pscustomobject]@{ runId = 'r1' }) -PlanApproval $pa -GeneratedBy 'engine' -Reason 'downloaded' }
        $d = @($rec.decisions | Where-Object { $_.what -eq 'checked where tempdb is on the SQL Server machines' })
        $d.Count | Should -Be 1
        $d[0].by | Should -Be 'approver@example.com'
        $d[0].atUtc | Should -Be '2026-11-16T10:00:00Z'
        $d[0].note | Should -Be 'sql-01, sql-02'
        $d[0].version | Should -Be ('a' * 64)
        $html = InModuleScope VmMigrationFactory -Parameters @{ r = $rec } { ConvertTo-VmfReportHtml -Record $r }
        $html | Should -Match 'SQL Server and the temporary disk: sql-01, sql-02'
    }

    It 'no decision for a sign-off with no such machine' {
        $pa = [pscustomobject]@{ schemaVersion = 4; approvedBy = [pscustomobject]@{ identity = 'approver@example.com' }; approvedUtc = '2026-11-16T10:00:00Z'
            planHash = ('a' * 64); note = 'reviewed'; waves = @('w1') }
        $rec = InModuleScope VmMigrationFactory -Parameters @{ pa = $pa } {
            ConvertTo-VmfMigrationRecord -Manifest ([pscustomobject]@{ runId = 'r1' }) -PlanApproval $pa -GeneratedBy 'engine' -Reason 'downloaded' }
        @($rec.decisions | Where-Object { $_.what -like '*tempdb*' }).Count | Should -Be 0
    }
}
