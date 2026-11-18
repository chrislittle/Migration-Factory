#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# The pages half of the old-record sweep (2026-11-12: one sweep, in two
# PRs): MIGRATIONS-PAGE-OLD-READERS-1, ATONCE-EARLIER-1, LOOSE-RUNS-WORDS-1
# and KERNEL-DEFAULT-EARLIER-1.
#
# Since 2026-11-11: nothing is public before 1.0, so no store holds a record
# an earlier version wrote. For each reader removed, the proof is that the
# writers of this version never write what it read:
#   - A plan sign-off: Approve-VmfPlan is its one writer, and it writes v4
#     (Get-VmfPlanApprovalSchemaVersion). A v1 or v2 sign-off is not read.
#   - How many machines at once: the planner writes 15, and Set-VmfWavePlan
#     and a decision write a choice only (Test-VmfThrottleTier). The wave
#     editor's layout is read the same way.
#   - The kernel default: the targets step always saves stop, and the service
#     and Set-VmfTargetChoice refuse another one.
#   - The Total Regional vCPUs: Test-VmfQuota, the one caller of
#     New-VmfCapacityClaim, always passes a whole number.
# The page halves are run in tests/js (finish-empty-lun-words, regional-quota,
# plan-follow, run-step, machines-at-once, kernel-choice).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:src = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
    $script:schemas = Join-Path $script:repoRoot 'schemas'
    $script:schemaOf = { param([string]$Name) [System.IO.File]::ReadAllText((Join-Path $script:schemas $Name)) | ConvertFrom-Json -Depth 40 }
    # The text of one function, comments removed.
    $script:functionCode = {
        param([string]$File, [string]$Name)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
        if (-not $fn) { throw "no function $Name in $File" }
        Get-VmfCodeOnly -Text $fn.Extent.Text -Language PowerShell
    }
}

Describe 'MIGRATIONS-PAGE-OLD-READERS-1: a plan sign-off is v3 only' {
    # SQL-TEMPDB-SIGNOFF-1 made it v4 (sqlTempdbChecked); still ONE version
    # only, the one Approve-VmfPlan writes.
    It 'the contract holds one version only, and Approve-VmfPlan writes it' {
        @((& $script:schemaOf 'plan-approval.schema.json').properties.schemaVersion.enum) | Should -Be @(4)
        InModuleScope VmMigrationFactory { Get-VmfPlanApprovalSchemaVersion } | Should -Be 4
    }

    It 'the narrowing has its migration note (hard rule 1)' {
        $notes = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' 'schema-migrations.md'))
        $notes | Should -Match '## plan-approval v3, plan-entry v33 and target-choices v8 narrowed \(2026-11-12'
    }

    It 'the consent to run on reads no version of the sign-off' {
        $code = & $script:functionCode (Join-Path $script:src 'Private' 'engine' 'PlanRun.ps1') 'Test-VmfPlanRunConsent'
        $code | Should -Not -Match 'schemaVersion'
    }

    It 'a decision moves a sign-off only with the wave approval, and writes it as v3' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:src 'Private' 'engine' 'DecisionCarry.ps1')
        $code | Should -Not -Match '\$paVersion' -Because 'the version of a sign-off is not read'
        $code | Should -Match '\$carrySignOff = \[bool\]\$CarryWaveApproval'
        $code | Should -Match 'Add-VmfAmendment -Document \$pa -Amendment \$amendment -Version \(Get-VmfPlanApprovalSchemaVersion\)'
    }
}

Describe 'MIGRATIONS-PAGE-OLD-READERS-1: every quota record carries the Total Regional vCPUs' {
    It 'Test-VmfQuota, the one maker of a quota record, passes a whole number' {
        $calls = @(Get-ChildItem $script:src -Recurse -Filter *.ps1 | Where-Object { (Get-VmfCodeOnly -Path $_.FullName) -match 'New-VmfCapacityClaim\s+-' })
        @($calls.Name) | Should -Be @('Test-VmfQuota.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:src 'Public' 'Test-VmfQuota.ps1')
        $code | Should -Match '-RegionalVcpus \$regionNeeded'
        $code | Should -Match '\$regionNeeded = \[int\]'
    }
}

Describe 'ATONCE-EARLIER-1: how many machines at once is one of the four choices' {
    It 'the plan-entry contract lists the four choices' {
        $t = (& $script:schemaOf 'plan-entry.schema.json').properties.policy.properties.throttle
        @($t.enum) | Should -Be @(5, 15, 30, 60)
        $t.PSObject.Properties['minimum'] | Should -BeNullOrEmpty
    }

    It 'the wave editor''s layout takes a choice, and refuses another number by name' {
        InModuleScope VmMigrationFactory {
            $w = @(ConvertTo-VmfWaveLayout -Layout @{ waves = @(@{ name = 'w1'; vmIds = @(); throttle = 30 }) })
            $w[0].Settings['throttle'] | Should -Be 30
            { ConvertTo-VmfWaveLayout -Layout @{ waves = @(@{ name = 'w1'; vmIds = @(); throttle = 7 }) } } |
                Should -Throw "How many machines at once must be one of the choices, 5, 15, 30 or 60 - got '7' for wave 'w1'.*"
        }
    }
}

Describe 'KERNEL-DEFAULT-EARLIER-1: the kernel default is stop' {
    It 'the target-choices contract holds stop only' {
        @((& $script:schemaOf 'target-choices.schema.json').properties.kernelDefault.enum) | Should -Be @('stop')
    }

    It 'Set-VmfTargetChoice takes stop only' {
        $kernelParam = (Get-Command Set-VmfTargetChoice).Parameters['KernelDefault']
        $set = @($kernelParam.Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })
        @($set[0].ValidValues) | Should -Be @('stop')
    }

    It 'the service refuses another default before it saves anything' {
        $claims = @(@{ typ = 'preferred_username'; val = 'person@example.com' }, @{ typ = 'roles'; val = 'Vmf.Operator' })
        $principal = ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5))))
        { Invoke-VmfFacadeSetTargets -Principal $principal -StorePath (Join-Path $TestDrive 'none') -Default 'current' -Choices @() -KernelDefault 'update' -AdviceVersion 'x' } |
            Should -Throw '400: the kernel default must be stop'
    }

    It 'New-VmfPlan and the lab check read no saved default' {
        Get-VmfCodeOnly -Path (Join-Path $script:src 'Public' 'New-VmfPlan.ps1') | Should -Not -Match 'kernelDefault'
    }

    # PUBLIC-SYNC-1: tests/lab does not ship to the public repository.
    It 'the lab check reads no saved default' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' 'lab'))) {
        Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tests' 'lab' '_KernelUpdateDrill.ps1') | Should -Not -Match 'kernelDefault'
    }
}

Describe 'LOOSE-RUNS-WORDS-1: a run outside a project is never said to be from before projects' {
    It 'no page, no help text, no manual page and no contract says it' {
        $files = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter *.js) +
            @(Get-ChildItem (Join-Path $script:repoRoot 'docs' 'manual') -Recurse -Filter *.md) +
            @(Get-Item (Join-Path $script:src 'data' 'operator-guide.json')) +
            @(Get-Item (Join-Path $script:schemas 'run-manifest.schema.json')) +
            @(Get-Item (Join-Path $script:src 'Private' 'state' 'StateStore.ps1'))
        $said = @($files | Where-Object { [System.IO.File]::ReadAllText($_.FullName) -match 'before projects|grandfathered' } | ForEach-Object Name)
        $said | Should -BeNullOrEmpty
    }

    It 'the Projects page has no help sentence for the group, only its name' {
        $page = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'src' 'dashboard' 'projects.js'))
        $page | Should -Not -Match 'looseHelp'
        $page | Should -Match "loose:\s+'Not in a project'"
    }
}

Describe 'OLD-STATE-READERS-PAGE-1: every writer of the rollback record writes rollbackOriginals' {
    It 'the one writer of the record, and the one that adds to it, record the disks swapped off in the same write' {
        $sm = & $script:functionCode (Join-Path $script:src 'Private' 'engine' 'StateMachine.ps1') 'Set-VmfRollbackRecord'
        $sm | Should -Match 'Add-VmfRollbackOriginalsOnDoc -Doc \$doc'
        $sp = & $script:functionCode (Join-Path $script:src 'Private' 'engine' 'SwapPending.ps1') 'Add-VmfSwapFinished'
        $sp | Should -Match 'Add-VmfRollbackOriginalsOnDoc -Doc \$doc'
        $writers = @(Get-ChildItem $script:src -Recurse -Filter *.ps1 | Where-Object { (Get-VmfCodeOnly -Path $_.FullName) -match '-NotePropertyName rollback\b' } | ForEach-Object Name)
        $writers | Should -Be @('StateMachine.ps1')
    }

    It 'a document with no rollbackOriginals has no entry - nothing comes from the captures' {
        $code = & $script:functionCode (Join-Path $script:src 'Private' 'engine' 'RollbackOriginals.ps1') 'Get-VmfRollbackOriginalEntries'
        $code | Should -Not -Match 'captured'
    }

    It 'the manual says nothing about a machine that rolled back before this version' {
        $said = @(Get-ChildItem (Join-Path $script:repoRoot 'docs' 'manual') -Recurse -Filter *.md | Where-Object { [System.IO.File]::ReadAllText($_.FullName) -match 'before this version' } | ForEach-Object Name)
        $said | Should -BeNullOrEmpty
    }
}