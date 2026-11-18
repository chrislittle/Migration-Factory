#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REAPER-1 - clearing up scans nobody finished.
#
# The wizard stores a migration as soon as names are set, even if nobody
# finishes the wizard, and that migration shows in reports and can be acted
# on.
#
# The wizard MUST create the run at step one - the scan is the first real
# action and it takes minutes, so deferring creation means having nothing to
# show. The consequence is that abandoning the wizard leaves a run for ever.
# The run page labels it "Still being prepared" and it can be deleted by hand;
# nothing cleared them up.
#
# THE THREE RULES, each a refusal to be clever:
#   1. setup stage only - a run with a plan is a decision somebody made
#   2. never automatic - a person runs it, having read what it would take
#   3. unknown is not old - a run whose date cannot be read is KEPT
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:NewStoreRoot {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-reap-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $root
    }
    # A run, aged on purpose. -WithPlan makes it a decision rather than a scan.
    function Global:AddRun {
        param($Root, [string]$Id, [int]$AgeDays = 60, [switch]$WithPlan, [switch]$NoDate)
        $path = "$Root/$Id"
        InModuleScope VmMigrationFactory -Parameters @{ p = $path; id = ($Id -split '/')[-1] } {
            Initialize-VmfRun -RunPath $p -RunId $id -Kind 'assessment' | Out-Null
        }
        $manifest = Get-Content (Join-Path $path 'run.json') -Raw | ConvertFrom-Json
        if ($NoDate) { $manifest.PSObject.Properties.Remove('createdUtc') }
        else { $manifest.createdUtc = (Get-Date).ToUniversalTime().AddDays(-$AgeDays).ToString('o') }
        $manifest | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $path 'run.json')
        if ($WithPlan) {
            InModuleScope VmMigrationFactory -Parameters @{ p = $path } {
                Write-VmfStoreJson -RunPath $p -RelPath 'plan.json' -Document @{ schemaVersion = 4; entries = @() } -Depth 6
            }
        }
        $path
    }
    function Global:AddProject {
        param($Root, [string]$Id)
        New-VmfProject -StorePath $Root -ProjectId $Id -Name $Id `
            -OnBehalfOf @{ Identity = 'sam@example.com'; TenantId = 't1' } | Out-Null
    }
}
AfterAll { Remove-Item 'function:\NewStoreRoot', 'function:\AddRun', 'function:\AddProject' -ErrorAction SilentlyContinue }

Describe 'REAPER-1: what it removes' {
    BeforeEach { $script:root = NewStoreRoot }
    AfterEach { if ($script:root -and (Test-Path $script:root)) { Remove-Item $script:root -Recurse -Force } }

    It 'removes an old scan that was never planned' {
        AddRun $script:root 'assessment-old' -AgeDays 60 | Out-Null
        $r = Remove-VmfAbandonedRuns -StorePath $script:root -RemovedBy 'sam@example.com' -Confirm:$false
        @($r.Removed).Count | Should -Be 1
        $r.Removed[0].Id | Should -Be 'assessment-old'
        Test-Path (Join-Path $script:root 'assessment-old') | Should -BeFalse
    }

    It 'KEEPS anything with a plan - that is a decision somebody made' {
        # Removing it is a question about safety copies, and this cmdlet does
        # not ask questions.
        AddRun $script:root 'planned-old' -AgeDays 90 -WithPlan | Out-Null
        $r = Remove-VmfAbandonedRuns -StorePath $script:root -RemovedBy 'sam@example.com' -Confirm:$false
        @($r.Removed).Count | Should -Be 0
        ($r.Kept | Where-Object { $_.Id -eq 'planned-old' }).Why | Should -Match 'plan'
        Test-Path (Join-Path $script:root 'planned-old') | Should -BeTrue
    }

    It 'keeps anything newer than the cutoff' {
        AddRun $script:root 'assessment-new' -AgeDays 3 | Out-Null
        $r = Remove-VmfAbandonedRuns -StorePath $script:root -OlderThanDays 30 -RemovedBy 'sam@example.com' -Confirm:$false
        @($r.Removed).Count | Should -Be 0
        Test-Path (Join-Path $script:root 'assessment-new') | Should -BeTrue
    }

    It 'and KEEPS a run whose age cannot be read - unknown is not old' {
        # The same rule the engine follows for an unknown generation or an
        # unknown image: unknown never becomes an answer.
        AddRun $script:root 'assessment-undated' -NoDate | Out-Null
        $r = Remove-VmfAbandonedRuns -StorePath $script:root -RemovedBy 'sam@example.com' -Confirm:$false
        @($r.Removed).Count | Should -Be 0
        ($r.Kept | Where-Object { $_.Id -eq 'assessment-undated' }).Why | Should -Match 'age cannot be read'
        Test-Path (Join-Path $script:root 'assessment-undated') | Should -BeTrue
    }

    It 'looks inside projects too, and names the run by its full id' {
        AddProject $script:root 'estate-one'
        AddRun $script:root 'estate-one/assessment-old' -AgeDays 60 | Out-Null
        $r = Remove-VmfAbandonedRuns -StorePath $script:root -RemovedBy 'sam@example.com' -Confirm:$false
        @($r.Removed).Count | Should -Be 1
        $r.Removed[0].Id | Should -Be 'estate-one/assessment-old'
        # The PROJECT survives: it is a name, and this cmdlet removes runs.
        Test-Path (Join-Path $script:root 'estate-one/project.json') | Should -BeTrue
    }

    It 'can be pointed at ONE project' {
        AddProject $script:root 'estate-one'
        AddProject $script:root 'estate-two'
        AddRun $script:root 'estate-one/assessment-old' -AgeDays 60 | Out-Null
        AddRun $script:root 'estate-two/assessment-old' -AgeDays 60 | Out-Null
        $r = Remove-VmfAbandonedRuns -StorePath $script:root -Project 'estate-one' -RemovedBy 'sam@example.com' -Confirm:$false
        @($r.Removed).Count | Should -Be 1
        Test-Path (Join-Path $script:root 'estate-two/assessment-old') | Should -BeTrue
    }
}

Describe 'REAPER-1: it says what it would do before it does it' {
    BeforeEach { $script:root = NewStoreRoot }
    AfterEach { if ($script:root -and (Test-Path $script:root)) { Remove-Item $script:root -Recurse -Force } }

    It '-WhatIf reports the candidates and removes nothing' {
        AddRun $script:root 'assessment-old' -AgeDays 60 | Out-Null
        $r = Remove-VmfAbandonedRuns -StorePath $script:root -WhatIf
        @($r.Candidates).Count | Should -Be 1 -Because 'it must say what an apply WOULD take'
        @($r.Removed).Count | Should -Be 0
        Test-Path (Join-Path $script:root 'assessment-old') | Should -BeTrue
    }

    It 'reports the age of each candidate, so the cutoff can be judged' {
        AddRun $script:root 'assessment-old' -AgeDays 45 | Out-Null
        $r = Remove-VmfAbandonedRuns -StorePath $script:root -WhatIf
        $r.Candidates[0].AgeDays | Should -BeGreaterThan 40
        $r.Candidates[0].CreatedUtc | Should -Not -BeNullOrEmpty
    }

    It 'and says why each kept run was kept' {
        AddRun $script:root 'planned-old' -AgeDays 90 -WithPlan | Out-Null
        AddRun $script:root 'assessment-new' -AgeDays 1 | Out-Null
        $r = Remove-VmfAbandonedRuns -StorePath $script:root -WhatIf
        @($r.Kept).Count | Should -Be 2
        @($r.Kept | Where-Object { -not $_.Why }) | Should -BeNullOrEmpty
    }
}

Describe 'REAPER-1: it never runs itself' {

    It 'nothing schedules it' {
        # Rule 2. A tidy-up that runs on a timer is a tidy-up nobody read.
        $repo = $script:repoRoot
        $hits = foreach ($f in Get-ChildItem $repo -Include '*.ps1', '*.yml', '*.json' -Recurse -File) {
            if ($f.FullName -like '*\.git\*') { continue }
            if ($f.Name -in @('Remove-VmfAbandonedRuns.ps1', 'AbandonedRuns.Tests.ps1')) { continue }
            $text = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
            if ($text -match 'Remove-VmfAbandonedRuns') { $f.Name }
        }
        # The facade may expose it (a person presses that too); a TIMER may not.
        foreach ($h in @($hits)) {
            $h | Should -Not -Match 'timer|Timer|schedule|Schedule' -Because 'it is never automatic'
        }
    }

    It 'and it deletes THROUGH Remove-VmfRun, which re-checks the stage itself' {
        # This cmdlet decides WHICH runs. Whether a run may go at all is that
        # cmdlet's decision, and it is the only caller of the bulk delete.
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Remove-VmfAbandonedRuns.ps1') -Raw
        $src | Should -Match 'Remove-VmfRun -RunPath'
        $src | Should -Not -Match 'Remove-VmfStorePrefix' -Because 'the bulk delete has one caller'
    }

    It 'keeps the safety copies - it is removing scans, which never made any' {
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Remove-VmfAbandonedRuns.ps1') -Raw
        $src | Should -Match '-KeepSafetyCopies'
        $src | Should -Not -Match '-DeleteSafetyCopies'
    }
}
