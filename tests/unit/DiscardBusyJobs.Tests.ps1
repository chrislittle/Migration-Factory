#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DISCARD-BUSY-JOBS-1: Delete this migration refused while the engine ran a
# wave, a restore, a finish or a delete of disks for the migration - a list
# written out at the check. The reserve and powerback jobs were not in it, so
# a migration could be deleted while a capacity reservation or a power return
# ran for it: the job then wrote into records the delete removed, and a
# reservation it made had no record left.
#
# Now every operation the engine can be started for has ONE decision, kept in
# one table in the service ($script:VmfEngineOperationKind), and both the
# delete and the start guard read it. These tests fail when an operation is
# added to the engine or to the start route with no decision.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:table = InModuleScope FacadeCore { $script:VmfEngineOperationKind }
}

Describe 'DISCARD-BUSY-JOBS-1: every engine operation has one decision' {
    It 'the table names every operation the start route takes, and no other' {
        $attr = (Get-Command -Module FacadeCore Invoke-VmfFacadeStartEngine -ErrorAction SilentlyContinue) ??
            (InModuleScope FacadeCore { Get-Command Invoke-VmfFacadeStartEngine })
        $set = @($attr.Parameters['Operation'].Attributes |
            Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] } |
            ForEach-Object { $_.ValidValues })
        $set.Count | Should -BeGreaterThan 10 -Because 'the start route reads its operations from a ValidateSet'
        @($script:table.Keys | Sort-Object) | Should -Be @($set | Sort-Object)
    }

    It 'the table names every operation the engine runs, and no other' {
        $file = Join-Path $script:repoRoot 'docker' 'entrypoint.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
        $switches = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $true) |
            Where-Object { @($_.Clauses | ForEach-Object { $_.Item1.Value }) -contains 'discard' })
        $switches.Count | Should -Be 1 -Because 'the engine picks its operation in one switch'
        $ops = @($switches[0].Clauses | ForEach-Object { [string]$_.Item1.Value })
        @($script:table.Keys | Sort-Object) | Should -Be @($ops | Sort-Object)
    }

    It 'every decision is one of the four kinds' {
        foreach ($k in $script:table.Keys) {
            $script:table[$k] | Should -BeIn @('assessment', 'changes', 'records', 'delete') -Because "the operation $k needs a decision"
        }
    }

    It 'the decision for each operation' {
        # Held here as well as in the service, so a change to one decision
        # fails a test and a reviewer reads it.
        $expected = [ordered]@{
            assess = 'assessment'; advise = 'assessment'; plan = 'assessment'
            wave = 'changes'; restore = 'changes'; finish = 'changes'; powerback = 'changes'
            reserve = 'changes'; deleteearlier = 'changes'; deletemade = 'changes'; checkvolumes = 'changes'
            release = 'records'; quota = 'records'; quotacheck = 'records'; retention = 'records'
            discard = 'delete'
        }
        foreach ($k in $expected.Keys) { $script:table[$k] | Should -Be $expected[$k] -Because "the decision for $k" }
    }

    It 'the delete is held by every job that writes the records of a migration' {
        $busy = InModuleScope FacadeCore { Get-VmfFacadeEngineOperation -Kind 'changes', 'records' }
        @($busy | Sort-Object) | Should -Be @(@('wave', 'restore', 'finish', 'powerback', 'reserve', 'deleteearlier',
                'deletemade', 'checkvolumes', 'release', 'quota', 'quotacheck', 'retention') | Sort-Object)
    }

    It 'the delete and the start guard read the table, with no list of their own' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $code | Should -Match "Test-VmfFacadeEngineRunning -Operation \(Get-VmfFacadeEngineOperation -Kind 'changes', 'records'\)"
        $code | Should -Match "-in \(Get-VmfFacadeEngineOperation -Kind 'changes'\)"
        $code | Should -Not -Match "'wave', 'restore', 'finish', 'reserve', 'powerback'"
    }
}
