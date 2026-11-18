#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REBUILD-REMOVE-LEFTOVERS-1 - Path B code and words that no flow reaches.
#
# The owner removed the rebuild around the same disks (Path B) on 2026-11-07
# (REBUILD-REMOVE-1). Three places still carried it:
#
#  - the lock verdict at Checking stopped a machine on a CanNotDelete lock
#    when its path was not A, with words that said the move deletes the
#    machine definition. PRECHECK refuses a path B entry first
#    (rebuildNotSupported), so no machine reached that branch. The verdict no
#    longer takes a path: ReadOnly stops every move, CanNotDelete stops none
#    and is said as an info line. That line must not say the move deletes
#    nothing: the unused rollback disks are deleted, and a
#    CanNotDelete lock refuses that (review; CANNOTDELETE-RESTORE-1).
#  - an install comment said the engine role "stops and rebuilds machines".
#  - the matrix owed a storage-pool drill "through a Path B recreate".


BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    function Script:Lock($name, $level, $scope = 'the resource group') {
        [pscustomobject]@{ name = $name; level = $level; scope = $scope }
    }
    function Script:Verdict($locks) {
        InModuleScope VmMigrationFactory -Parameters @{ l = $locks } { Get-VmfLockVerdict -Locks $l }
    }
}

Describe 'REBUILD-REMOVE-LEFTOVERS-1: the lock verdict has no rebuild branch' {

    It 'the verdict takes no migration path' {
        $cmd = InModuleScope VmMigrationFactory { Get-Command Get-VmfLockVerdict }
        $cmd.Parameters.ContainsKey('Path') | Should -BeFalse -Because 'every move is in place, so the path changes nothing a lock refuses'
    }

    It 'a CanNotDelete lock does not stop the move, and the info line names it' {
        $v = Script:Verdict @(Script:Lock 'no-delete' 'CanNotDelete')
        $v.Blocked | Should -BeFalse -Because 'a CanNotDelete lock does not refuse a resize or a disk swap'
        $v.Detail | Should -Match 'no-delete'
        $v.Detail | Should -Match 'CanNotDelete'
        $v.Detail | Should -Not -Match '(?i)rebuil|\bpath\b' -Because 'no move rebuilds a machine, and the operator does not see a path'
    }

    It 'the info line does not say the move deletes nothing' {
        # Review finding: a move deletes the rollback disks that it did
        # not use, and Restore this machine deletes disks too. A CanNotDelete
        # lock refuses those deletes, so a line that says nothing is deleted is false.
        $v = Script:Verdict @(Script:Lock 'no-delete' 'CanNotDelete')
        # The words before the colon; after it come the lock names and levels
        # (here "no-delete (CanNotDelete)"), which are names, not a claim.
        $words = ($v.Detail -split ':', 2)[0]
        $words | Should -Match 'do not stop the move'
        $words | Should -Not -Match '(?i)delet|harmless|no effect'
    }

    It 'a ReadOnly lock still stops every move, with resourceLocked' {
        $v = Script:Verdict @((Script:Lock 'no-delete' 'CanNotDelete'), (Script:Lock 'prod-guard' 'ReadOnly'))
        $v.Blocked | Should -BeTrue
        $v.Reason | Should -Be 'resourceLocked'
        $v.Detail | Should -Match 'prod-guard'
        $v.Detail | Should -Not -Match 'no-delete'
    }

    It 'the lock check no longer writes resourceDeleteLocked, and says nothing of a rebuild' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'validate' 'ResourceLocks.ps1')
        $code | Should -Not -Match 'resourceDeleteLocked'
        $code | Should -Not -Match '(?i)rebuil'
        $code | Should -Not -Match "-eq\s+'A'" -Because 'the verdict does not branch on the path any more'
    }

    It 'PRECHECK gives the verdict no path' {
        $sm = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $call = @([regex]::Matches($sm, 'Get-VmfLockVerdict[^\r\n]*') | ForEach-Object { $_.Value })
        $call.Count | Should -Be 1
        $call[0] | Should -Not -Match '-Path'
    }
}


Describe 'REBUILD-REMOVE-LEFTOVERS-1: the install comment says what the engine role does' {

    It 'no install template says the engine rebuilds machines' {
        foreach ($file in Get-ChildItem (Join-Path $script:repoRoot 'infra') -Filter '*.bicep' -Recurse) {
            Get-Content $file.FullName -Raw | Should -Not -Match '(?i)\brebuil' -Because "$($file.Name) must not say a move rebuilds a machine"
        }
        $platform = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
        $platform | Should -Match '(?i)which stops and resizes machines'
    }
}

# PUBLIC-SYNC-1: the lab test matrix does not ship to the public repository.
Describe 'REBUILD-REMOVE-LEFTOVERS-1: the matrix owes no drill of a rebuild' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'docs' 'matrix.md'))) {
    BeforeAll {
        $tool = Join-Path $script:repoRoot 'tools' 'New-VmfMatrixReport.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($tool, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                          $n.Name -eq 'Get-VmfMatrixCells' }, $true)
        $script:cells = & ([scriptblock]::Create($fn.Body.Extent.Text.Trim('{', '}')))
        $script:matrixDoc = Get-Content (Join-Path $script:repoRoot 'docs' 'matrix.md') -Raw
    }

    It 'no owed drill names a Path B recreate' {
        $drill = @($script:cells | Where-Object { $_.ProvenBy -eq 'drill' })
        $drill.Count | Should -BeGreaterThan 0
        foreach ($c in $drill) { $c.Note | Should -Not -Match '(?i)Path B|recreat|rebuil' }
    }

    It 'the storage-pool drill names the in-place upgrade (Preview), and the page says so' {
        $pool = @($script:cells | Where-Object { $_.ProvenBy -eq 'drill' -and $_.Note -match 'STORAGE-SPACES-1' })
        $pool.Count | Should -Be 1
        $pool[0].Note | Should -Match ([regex]::Escape('in-place upgrade (Preview)'))
        $pool[0].Note | Should -Match 'NVMe'
        $script:matrixDoc | Should -Match ([regex]::Escape($pool[0].Note))
    }
}
