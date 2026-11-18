#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
NOT-IN-WAVE-QUEUED-1: a machine in no wave that never ran is not part of the
migration, so the record and the service's run summary leave it out - the same
rule the Migrations page and the Reports page ask (VmfHelp.outsideRun).

The wave editor's Remove puts a machine of the plan in no wave (wave
`unscheduled`, path A). No wave takes it. The record listed it as "Not
started", and the service's summary counted it as not started - so the Reports
page read a finished migration as still going. The rule since 2026-11-12: a
machine that is not part of a migration and its waves is never shown.

One answer in two languages: tests/fixtures/entry-outside-run.json, which
tests/js/not-in-wave-queued.test.js runs against help.js.
#>
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:cases = (Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'entry-outside-run.json') -Raw | ConvertFrom-Json).cases
    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
    $script:plan = [pscustomobject]@{
        schemaVersion = 1
        waveOrder     = @('wave-1')
        entries       = @(
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:sub)in-wave"; wave = 'wave-1'; path = 'A'; policy = [pscustomobject]@{ requireApproval = $false } }
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:sub)removed"; wave = 'unscheduled'; path = 'A'; policy = [pscustomobject]@{ requireApproval = $false } }
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:sub)ran-then-removed"; wave = 'unscheduled'; path = 'A'; policy = [pscustomobject]@{ requireApproval = $false } }
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:sub)manual"; wave = 'unscheduled'; path = 'MANUAL'; policy = [pscustomobject]@{} }
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:sub)excluded"; wave = 'unscheduled'; path = 'EXCLUDED'; policy = [pscustomobject]@{} }
        )
    }
    $script:docs = @(
        [pscustomobject]@{ vmId = "$($script:sub)ran-then-removed"; state = 'FAILED_ROLLED_BACK' }
    )
}

Describe 'Test-VmfEntryOutsideRun' {
    It 'gives every shared case the answer the pages give' {
        @($script:cases).Count | Should -BeGreaterOrEqual 12 -Because 'the fixture loaded'
        foreach ($c in $script:cases) {
            $got = InModuleScope VmMigrationFactory -Parameters @{ e = $c.entry; d = $c.doc } { Test-VmfEntryOutsideRun -Entry $e -StateDoc $d }
            $got | Should -Be ([bool]$c.outside) -Because $c.name
        }
    }

    It 'reads a hashtable the same way as a JSON object' {
        InModuleScope VmMigrationFactory {
            Test-VmfEntryOutsideRun -Entry @{ path = 'A'; wave = 'unscheduled' } -StateDoc $null | Should -BeTrue
            Test-VmfEntryOutsideRun -Entry @{ path = 'A'; wave = 'unscheduled' } -StateDoc @{ state = 'MIGRATED' } | Should -BeFalse
            Test-VmfEntryOutsideRun -Entry @{ path = 'MANUAL'; wave = 'unscheduled' } -StateDoc $null | Should -BeFalse
            Test-VmfEntryOutsideRun -Entry @{ path = 'A'; wave = 'w1' } -StateDoc $null | Should -BeFalse
        }
    }
}

Describe 'The migration record leaves out a machine in no wave that never ran' {
    BeforeAll {
        $script:record = InModuleScope VmMigrationFactory -Parameters @{ p = $script:plan; d = $script:docs } {
            ConvertTo-VmfMigrationRecord -Manifest @{ runId = 'r' } -Plan $p -StateDocs @($d) -GeneratedBy 'test' -Reason 'downloaded'
        }
        $script:names = @($script:record.machines | ForEach-Object { ([string]$_.vmId -split '/')[-1] })
    }

    It 'has no row for the removed machine' {
        $script:names | Should -Not -Contain 'removed'
    }

    It 'keeps a machine with a state document - its history matters' {
        $script:names | Should -Contain 'ran-then-removed'
        ($script:record.machines | Where-Object { $_.vmId -like '*ran-then-removed' }).outcome | Should -Be 'rolledBack'
    }

    It 'keeps the machines the plan does not move, as Not moved' {
        $script:names | Should -Contain 'manual'
        $script:names | Should -Contain 'excluded'
        @($script:record.machines | Where-Object { $_.outcome -eq 'notMoved' }).Count | Should -Be 2
    }

    It 'counts in its summary only the machines it lists' {
        $script:names.Count | Should -Be 4
        $script:record.summary['notStarted'] | Should -Be 1 -Because 'only in-wave waits to start'
        ($script:record.summary.Values | Measure-Object -Sum).Sum | Should -Be 4
    }
}

Describe "The service's run summary leaves out a machine in no wave that never ran" {
    BeforeAll {
        $script:store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-notinwave-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:store; p = $script:plan; d = $script:docs } {
            Initialize-VmfRun -RunPath $rp -RunId 'notinwave' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document $p
            foreach ($doc in $d) { Write-VmfStoreJson -RunPath $rp -RelPath "state/$(([string]$doc.vmId -split '/')[-1]).json" -Depth 8 -Document $doc }
        }
        $script:summary = Get-VmfFacadeRunSummary -StorePath $script:store
    }
    AfterAll { if (Test-Path $script:store) { Remove-Item $script:store -Recurse -Force } }

    It 'does not count the removed machine as not started' {
        $script:summary.outcomes.notStarted | Should -Be 1 -Because 'only in-wave waits to start; the removed machine is not part of the migration'
        $script:summary.outcomes.rolledBack | Should -Be 1 -Because 'the machine with history is counted'
    }

    It 'gives a total of the machines it shows' {
        $script:summary.total | Should -Be 4
        $no = @($script:summary.waves | Where-Object { $_.wave -eq 'unscheduled' })
        $no.Count | Should -Be 1
        $no[0].total | Should -Be 3 -Because 'ran-then-removed, manual and excluded; not the removed machine'
    }

    It 'gives no wave of nothing when every machine of a group is left out' {
        $rp = Join-Path $script:store '..' "vmf-notinwave-b-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $rp = [System.IO.Path]::GetFullPath($rp)
        try {
            $only = [pscustomobject]@{ schemaVersion = 1; entries = @(
                [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:sub)a"; wave = 'wave-1'; path = 'A'; policy = [pscustomobject]@{} }
                [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:sub)b"; wave = 'unscheduled'; path = 'A'; policy = [pscustomobject]@{} }) }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; p = $only } {
                Initialize-VmfRun -RunPath $rp -RunId 'notinwave-b' | Out-Null
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document $p
            }
            $s = Get-VmfFacadeRunSummary -StorePath $rp
            @($s.waves | ForEach-Object { $_.wave }) | Should -Be @('wave-1')
            $s.total | Should -Be 1
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }
}

Describe 'Set-VmfWavePlan refuses a wave named as the product names no wave' {
    # The engine skips a wave named unscheduled in any case, and the Migrations
    # page uses unplanned for its own bucket. A wave a person gave such a name
    # would never run, or show no Start. So the save refuses them, before it
    # writes anything - all but exactly 'unscheduled', which means no wave.
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wavename-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $mk = { param($name, $wave)
            [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:sub)$name"; wave = $wave; appGroup = $name
                assessment = [ordered]@{ classification = 'ReadyAfterPrep'; os = 'Linux'; sourceSize = 'Standard_D2ds_v4'; location = 'centralus'; availabilitySetId = '' }
                target = [ordered]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe' }
                path = 'A'; policy = [ordered]@{ targetGeneration = 'v6'; requireApproval = $true } } }
        $plan = [ordered]@{ schemaVersion = 4; entries = @((& $mk 'a' 'wave-1'), (& $mk 'b' 'wave-1')) }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; plan = $plan } {
            Initialize-VmfRun -RunPath $rp -RunId 'wavename' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan
        }
        $script:before = Get-Content (Join-Path $script:rp 'plan.json') -Raw
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'refuses <Name>, and changes nothing' -ForEach @(
        @{ Name = 'Unscheduled' }, @{ Name = 'UNSCHEDULED' }, @{ Name = 'unplanned' }, @{ Name = 'UnPlanned' }
    ) {
        $waves = @(@{ name = $Name; vmIds = @("$($script:sub)a") }, @{ name = 'wave-1'; vmIds = @("$($script:sub)b") })
        { Set-VmfWavePlan -RunPath $script:rp -PlanPath (Join-Path $script:rp 'plan.json') -Layout @{ waves = $waves } -Confirm:$false } |
            Should -Throw "*Wave name '$Name' is not usable - the product uses this name for the machines that are not in a wave*"
        Get-Content (Join-Path $script:rp 'plan.json') -Raw | Should -Be $script:before
    }

    It 'takes exactly unscheduled, the planner''s own word, as no wave' {
        $waves = @(@{ name = 'unscheduled'; vmIds = @("$($script:sub)a") }, @{ name = 'wave-1'; vmIds = @("$($script:sub)b") })
        Set-VmfWavePlan -RunPath $script:rp -PlanPath (Join-Path $script:rp 'plan.json') -Layout @{ waves = $waves } -Confirm:$false | Out-Null
        $a = @((Get-Content (Join-Path $script:rp 'plan.json') -Raw | ConvertFrom-Json).entries | Where-Object { $_.vmId -like '*/a' })[0]
        $a.wave | Should -BeExactly 'unscheduled'
    }

    It 'takes a name that only starts like one of them' {
        $waves = @(@{ name = 'unscheduled-2'; vmIds = @("$($script:sub)a") }, @{ name = 'wave-1'; vmIds = @("$($script:sub)b") })
        { Set-VmfWavePlan -RunPath $script:rp -PlanPath (Join-Path $script:rp 'plan.json') -Layout @{ waves = $waves } -Confirm:$false } | Should -Not -Throw
    }

    It 'says the same names as the wave editor' {
        $page = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.js') -Raw
        $page | Should -Match "const RESERVED_WAVE_NAMES = \['unscheduled', 'unplanned'\];"
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Set-VmfWavePlan.ps1') -Raw
        $src | Should -Match "\`$name -cne 'unscheduled' -and \`$name -in @\('unscheduled', 'unplanned'\)"
    }
}