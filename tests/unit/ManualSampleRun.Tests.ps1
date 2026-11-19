#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MANUAL-SHOTS-1: the sample migration the manual's report picture is written
# from (tools/New-VmfManualSampleRun.ps1).
#
# Hard rule 1: everything that crosses a boundary has a schema. This sample is
# read by the module's own report writer, so a document in it that its schema
# refuses is a report picture of something the product could never write. The
# independent review found three of them in the first version - a run manifest
# at version 1 (the schema says 9), acceptances with no options hash or
# settings, and an acknowledgement with no statement - and the report rendered
# anyway, which is exactly why a rendering is no proof.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:schemas = Join-Path $script:repoRoot 'schemas'
    $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-manual-run-test-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $null = & (Join-Path $script:repoRoot 'tools' 'New-VmfManualSampleRun.ps1') -RunPath $script:runPath

    # A document and the schema it must satisfy. Test-Json writes the reason
    # to the error stream; it is returned so a failure says what is wrong.
    function Script:SchemaErrors([string]$Json, [string]$Schema) {
        $errs = @()
        $ok = Test-Json -Json $Json -SchemaFile (Join-Path $script:schemas $Schema) -ErrorAction SilentlyContinue -ErrorVariable errs
        if ($ok) { return '' }
        return (@($errs | ForEach-Object { $_.Exception.Message }) -join '; ')
    }
    function Script:FileErrors([string]$Rel, [string]$Schema) {
        Script:SchemaErrors -Json (Get-Content (Join-Path $script:runPath $Rel) -Raw) -Schema $Schema
    }
}
AfterAll {
    if ($script:runPath -and (Test-Path $script:runPath)) { Remove-Item $script:runPath -Recurse -Force }
}

Describe 'MANUAL-SHOTS-1: the sample migration is in the shapes the product writes' {
    It 'the run manifest, the assessment and the plan sign-off satisfy their schemas' {
        Script:FileErrors 'run.json' 'run-manifest.schema.json' | Should -BeNullOrEmpty
        Script:FileErrors 'assessment.json' 'assessment.schema.json' | Should -BeNullOrEmpty
        Script:FileErrors 'plan-approval.json' 'plan-approval.schema.json' | Should -BeNullOrEmpty
    }

    It 'every plan entry satisfies the plan-entry schema' {
        $plan = Get-Content (Join-Path $script:runPath 'plan.json') -Raw | ConvertFrom-Json
        @($plan.entries).Count | Should -Be 5
        foreach ($e in $plan.entries) {
            Script:SchemaErrors -Json ($e | ConvertTo-Json -Depth 20) -Schema 'plan-entry.schema.json' |
                Should -BeNullOrEmpty -Because "the entry of $($e.vmId)"
        }
    }

    It 'every machine state, acceptance, acknowledgement and quota record satisfies its schema' {
        $states = @(Get-ChildItem (Join-Path $script:runPath 'state') -Filter '*.json')
        $states.Count | Should -Be 5
        foreach ($s in $states) { Script:FileErrors "state/$($s.Name)" 'vm-state.schema.json' | Should -BeNullOrEmpty -Because $s.Name }
        $accepted = @(Get-ChildItem (Join-Path $script:runPath 'acceptances') -Filter '*.json')
        $accepted.Count | Should -Be 2
        foreach ($a in $accepted) { Script:FileErrors "acceptances/$($a.Name)" 'wave-options-acceptance.schema.json' | Should -BeNullOrEmpty -Because $a.Name }
        Script:FileErrors 'acknowledgements/infrastructure-as-code.json' 'run-acknowledgement.schema.json' | Should -BeNullOrEmpty
        foreach ($c in @(Get-ChildItem (Join-Path $script:runPath 'capacity') -Filter '*.json')) {
            Script:FileErrors "capacity/$($c.Name)" 'capacity-claim.schema.json' | Should -BeNullOrEmpty -Because $c.Name
        }
    }

    It 'the module writes its report from it, with every section the manual describes' {
        $html = Get-Content (New-VmfReport -OutPath $script:runPath) -Raw
        foreach ($section in 'Results', 'Moves', 'Machines', 'Exceptions', 'Sign-off', 'Changes to match in your infrastructure code') {
            $html | Should -Match ([regex]::Escape($section)) -Because "the report picture shows $section"
        }
    }

    It 'ACCEPT-NAME-1: the tool names an acceptance file as the product does, for every wave name' {
        $waves = @('web-pilot', 'web-report-db', 'wave_1', 'wave.1', 'Wave-1', 'App.A_b', 'x')
        $tool = @(& (Join-Path $script:repoRoot 'tools' 'New-VmfManualSampleRun.ps1') -AcceptanceNameFor $waves)
        $module = @(InModuleScope VmMigrationFactory -Parameters @{ w = $waves } { foreach ($one in $w) { Get-VmfWaveOptionsAcceptancePath -Wave $one } })
        $tool.Count | Should -Be $waves.Count
        for ($i = 0; $i -lt $waves.Count; $i++) { $tool[$i] | Should -BeExactly $module[$i] -Because $waves[$i] }
    }

    It 'ACCEPT-NAME-1: the sample''s acceptances are under that name, which the Migrations page reads' {
        $names = @(Get-ChildItem (Join-Path $script:runPath 'acceptances') -Filter '*.json' | ForEach-Object { "acceptances/$($_.Name)" } | Sort-Object)
        $want = @(InModuleScope VmMigrationFactory { 'web-pilot', 'web-report-db' | ForEach-Object { Get-VmfWaveOptionsAcceptancePath -Wave $_ } } | Sort-Object)
        $names | Should -Be $want
        foreach ($n in $names) { $n | Should -BeLike 'acceptances/wave-options-*.json' }
    }

    It 'refuses a folder that exists, rather than mixing a sample into it' {
        { & (Join-Path $script:repoRoot 'tools' 'New-VmfManualSampleRun.ps1') -RunPath $script:runPath } | Should -Throw '*exists already*'
    }
}
