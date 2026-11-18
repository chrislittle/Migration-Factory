# ROLE-SNAP-1: an ARM call that reads one resource to build another needs
# permission on BOTH, and the second one is invisible in the cmdlet.
#
# MEASURED on a live install, 2026-09-18, on the first restore anybody ever ran.
# "Put this machine back" stopped the machine, created the new disk, and was
# then refused:
#
#   has permission to perform 'Microsoft.Compute/disks/write' on scope
#   '.../disks/..-restored-..'; however, it does not have permission to perform
#   'Microsoft.Compute/disks/beginGetAccess/action' on the linked scope(s)
#   '.../snapshots/...-prist'
#
# Creating a disk FROM a snapshot makes that snapshot a LINKED SCOPE, and Azure
# evaluates a second action against it. The role granted snapshots read, write
# and delete - and not this. So RESTORE HAD NEVER WORKED IN ANY INSTALL: the
# recovery path, the one that runs when something has already gone wrong.
#
# THE ACTION NAME LOOKS WRONG FOR A SNAPSHOT AND IS NOT. Microsoft's own
# built-in 'Disk Snapshot Contributor' carries
# Microsoft.Compute/disks/beginGetAccess/action alongside the snapshots ones,
# for exactly this case. That is what settles it as the right action rather than
# snapshots/beginGetAccess - read from Azure, not guessed.
#
# THE CLASS WAS ALREADY WRITTEN DOWN. rbac-actions.json has said since the last
# instance that deriving the role from the code is "necessary but not
# sufficient", that "a single ARM call can demand permissions on resources the
# caller never mentions", and that every addition should be "treated as a
# hypothesis until a drill has run on the role alone". The restore path had
# never been drilled - see ROLE-DRILL-1.
#
# So this pins the two things a reader can check without Azure: the action is
# there, and the reason is written where the next person will meet it.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw |
        ConvertFrom-Json
    $script:fromSnapshot = @($script:map.operations | Where-Object { $_.cmdlet -eq 'New-AzDisk' })
}

Describe 'ROLE-SNAP-1: the role covers the linked scope, not only the target' {

    It 'the map was read and holds the call that builds a disk from a copy' {
        # THE VACUITY GUARD. If this operation is ever renamed, the check below
        # would pass on an empty collection and stop covering anything.
        @($script:map.operations).Count | Should -BeGreaterThan 20
        $script:fromSnapshot.Count | Should -Be 1 `
            -Because 'exactly one mapped call creates a disk from a safety copy'
    }

    It 'THE DEFECT: it carries the action Azure checks against the snapshot' {
        # Without this, a restore stops after the machine has been stopped and
        # the new disk created - the worst moment to be refused.
        $script:fromSnapshot[0].actions | Should -Contain 'Microsoft.Compute/disks/beginGetAccess/action' `
            -Because 'Azure evaluates it against the snapshot the disk is built from'
    }

    It 'and still carries the obvious one, so the fix did not swap them' {
        $script:fromSnapshot[0].actions | Should -Contain 'Microsoft.Compute/disks/write'
    }

    It 'the reason is recorded where somebody changing this will read it' {
        # A permission with no reason is the first thing removed by anybody
        # tidying a role, and this one looks like a typo.
        $script:fromSnapshot[0].why | Should -Match 'linked scope' `
            -Because 'the next reader must learn why an action named for disks sits on a snapshot'
        $script:fromSnapshot[0].why | Should -Match 'Disk Snapshot Contributor' `
            -Because 'and where the answer was read from, so it can be checked again'
    }

    It 'the standing lesson about sufficiency is still on the file' {
        # This instance is the second. The lesson was already there and the
        # restore path had simply never been exercised against the role.
        $script:map.verificationLesson | Should -Match '(?i)not sufficient'
        $script:map.verificationLesson | Should -Match '(?i)hypothesis'
    }
}
