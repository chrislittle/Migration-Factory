#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EVAL-L2 and M15 - one state vocabulary, four copies of it.
#
# L2  SAFETY_PRISTINE has been the DEFAULT safety copy since SAFETY-2, and it
#     was never added to the vm-state enum. Every machine that took a pristine
#     copy wrote a document its own contract rejects. Nothing caught it because
#     the only thing ever validated against that schema was a hand-written
#     sample, and the sample never used the state - the schema was tested
#     against a fixture instead of against what the code emits.
#
# M15 Two lifecycle guards and the dashboard tested for a state called QUEUED.
#     Nothing has ever written QUEUED; the first state is PLANNED. So every
#     planned machine counted as started: a run that had never run reported
#     itself under way, and - the expensive half - refused to be discarded,
#     saying it was still working on a machine nothing had touched. That is the
#     stuck run with no way out that the owner hit in the lab.
#
# Both are the same defect: a vocabulary copied rather than read. So this file
# derives every copy from the engine's declaration and compares.
BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:states = InModuleScope VmMigrationFactory { Get-VmfEngineStates }
    $script:sm = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
    $script:schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json
    $script:lifecycle = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'RunLifecycle.ps1') -Raw
}

Describe 'EVAL-L2: the contract knows every state the engine can write' {
    It 'the schema enum is exactly the declared vocabulary' {
        @($script:schema.properties.state.enum) | Sort-Object |
            Should -Be (@($script:states.All) | Sort-Object)
    }

    It 'specifically including the one that was missing' {
        @($script:schema.properties.state.enum) | Should -Contain 'SAFETY_PRISTINE'
    }

    It 'a document in that state validates - which it did not before' {
        $doc = [ordered]@{
            schemaVersion = (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion }); runId = 'r1'
            vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
            wave = 'w1'; state = 'SAFETY_PRISTINE'
            history = @([ordered]@{ tsUtc = '2026-08-29T00:00:00Z'; state = 'SAFETY_PRISTINE'; outcome = 'ok' })
        }
        $schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        Test-Json -Json ($doc | ConvertTo-Json -Depth 20) -SchemaFile $schemaFile -ErrorAction Stop |
            Should -BeTrue
    }

    It 'every handler in the state machine is a declared working state' {
        # The handler table is the other place a state is really introduced.
        $block = [regex]::Match($script:sm, '(?s)\$handlers = @\{.*?\n    \}').Value
        $block | Should -Not -BeNullOrEmpty
        $keys = @([regex]::Matches($block, '(?m)^\s{8}([A-Z_]+)\s*=') | ForEach-Object { $_.Groups[1].Value })
        @($keys).Count | Should -BeGreaterThan 5
        foreach ($k in $keys) {
            $script:states.Working | Should -Contain $k -Because "handler '$k' can be written to a state document"
        }
    }

    It 'and every working state has a handler - an unreachable state is a stall' {
        $block = [regex]::Match($script:sm, '(?s)\$handlers = @\{.*?\n    \}').Value
        $keys = @([regex]::Matches($block, '(?m)^\s{8}([A-Z_]+)\s*=') | ForEach-Object { $_.Groups[1].Value })
        foreach ($s in $script:states.Working) {
            $keys | Should -Contain $s -Because "a machine reaching '$s' with no handler throws mid-run"
        }
    }

    It 'every state says whether it can have changed the machine' {
        InModuleScope VmMigrationFactory {
            foreach ($s in (Get-VmfEngineStates).All) {
                Get-VmfStateMutates -State $s | Should -BeIn @('no', 'power', 'guest')
            }
        }
    }
}

Describe 'EVAL-M15: nothing tests for a state that does not exist' {
    It 'no code compares against QUEUED' {
        # Comments may say the word - that is how this stays explained - and
        # min.js is vendored. Case-SENSITIVE, because the dashboard's label for
        # PLANNED is the ordinary English word "Queued", which is fine; what
        # must not exist is a comparison against the state name QUEUED.
        $offenders = foreach ($f in (Get-ChildItem (Join-Path $script:repoRoot 'src') -Recurse -Include '*.ps1', '*.html', '*.js')) {
            if ($f.Name -like '*.min.js') { continue }
            $code = (Get-VmfCodeOnly -Path $f.FullName)
            if (($code -join "`n") -cmatch "QUEUED") { $f.Name }
        }
        $offenders -join ', ' | Should -BeNullOrEmpty -Because 'no engine has ever written QUEUED; the first state is PLANNED'
    }

    It 'the not-started state is the one the store actually writes' {
        $store = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'StateStore.ps1') -Raw
        $written = @([regex]::Matches($store, "state\s+=\s+'([A-Z_]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $written | Should -Contain $script:states.NotStarted
        $script:states.NotStarted | Should -Be 'PLANNED'
    }

    It 'the lifecycle guards read the declaration rather than a literal' {
        $script:lifecycle | Should -Match 'Get-VmfEngineStates'
        # Both functions also carried their own copy of the TERMINAL list -
        # the same defect one function over. Neither may reconstruct it.
        $script:lifecycle | Should -Not -Match "@\('MIGRATED'"
    }
}

Describe 'EVAL-M15: a run that never started can be thrown away' {
    BeforeEach {
        $script:run = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-lc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:vm = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; vm = $script:vm } {
            Initialize-VmfRun -RunPath $rp -RunId 'lc-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'lc-test' -VmId $vm -Wave 'w1' | Out-Null
        }
        $script:plan = [pscustomobject]@{ entries = @([pscustomobject]@{ vmId = $script:vm; path = 'A' }) }
        $script:docs = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; vm = $script:vm } {
            @(Read-VmfStateDoc -RunPath $rp -VmId $vm) }
    }
    AfterEach { if (Test-Path $script:run) { Remove-Item $script:run -Recurse -Force } }

    It 'the machine really is written as PLANNED' {
        @($script:docs)[0].state | Should -Be 'PLANNED'
    }

    It 'a planned-only run reads as planned, not as running' {
        $r = InModuleScope VmMigrationFactory -Parameters @{ p = $script:plan; d = $script:docs } {
            Get-VmfRunStage -Plan $p -StateDocs $d }
        $r.Stage | Should -Be 'planned' -Because 'nothing has been attempted on any machine'
    }

    It 'and it can be discarded - it was refusing, claiming a machine was mid-move' {
        $r = InModuleScope VmMigrationFactory -Parameters @{ p = $script:plan; d = $script:docs } {
            Test-VmfRunDiscardable -Plan $p -StateDocs $d }
        $r.Ok | Should -BeTrue -Because 'a PLANNED machine has not been touched, so there is nothing to lose'
    }

    It 'while a machine genuinely mid-move is still refused' {
        $moving = @([pscustomobject]@{ vmId = $script:vm; state = 'CONVERTING' })
        $r = InModuleScope VmMigrationFactory -Parameters @{ p = $script:plan; d = $moving } {
            Test-VmfRunDiscardable -Plan $p -StateDocs $d }
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'CONVERTING'
    }
}
