#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EVAL-H4, M1 and M2 - the family the audit called worse than invisibility.
#
# machineState is the one field the design says an operator cannot be told
# wrongly; the dashboard renders it as "Nothing on this machine was changed".
# It was assigned by an else-branch that ASSUMED what had happened, and three
# paths were wrong:
#
#   H4  SAFETY_PRISTINE deallocates BEFORE it snapshots, and SAFETY_COPY runs
#       on a machine already deallocated and never starts it. Any snapshot
#       failure that survived its attempts therefore parked a production
#       machine POWERED OFF and reported that nothing was changed. No page
#       shows power state, so in an overnight wave it stays down until somebody
#       notices it is unreachable.
#   M1  The guest fixers rewrite fstab, GRUB, the initramfs and the boot
#       registry, then decide their verdict at the end - so BLOCKED means
#       "changed, then failed", and the engine stamped it 'untouched'.
#   M2  Set-NvmeReady crashed on any image with no vpci service - the case its
#       own checker calls normal - so such an image could never be prepared.
#
# An operator who is told nothing happened stops looking. That is why these are
# worse than a missing message.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
}

Describe 'EVAL-H4/M1: what a state can have done is declared, not assumed' {
    It 'only the states that truly touch nothing claim to have touched nothing' {
        InModuleScope VmMigrationFactory {
            Get-VmfStateMutates -State 'PLANNED'  | Should -Be 'no'
            Get-VmfStateMutates -State 'PRECHECK' | Should -Be 'no'
        }
    }

    It 'the states that stop the machine are marked as power-affecting' {
        # SAFETY_PRISTINE deallocates before snapshotting; SAFETY_COPY runs on a
        # machine STOPPED already deallocated and never starts it.
        InModuleScope VmMigrationFactory {
            foreach ($s in 'SAFETY_PRISTINE', 'STOPPED', 'SAFETY_COPY') {
                Get-VmfStateMutates -State $s | Should -Be 'power' -Because "$s can leave the machine off"
            }
        }
    }

    It 'guest prep is marked as changing the machine' {
        InModuleScope VmMigrationFactory {
            Get-VmfStateMutates -State 'GUEST_PREP' | Should -Be 'guest'
        }
    }

    It 'an unrecognised state is assumed to have changed something, never the reverse' {
        # Unknown must never resolve towards "nothing happened".
        InModuleScope VmMigrationFactory {
            Get-VmfStateMutates -State 'SOMETHING_NEW' | Should -Be 'guest'
        }
    }
}

Describe 'EVAL-H4: a machine left stopped is reported as stopped' {
    It 'says restored when it comes back' {
        InModuleScope VmMigrationFactory {
            Mock Start-VmfVm { }
            $r = Resolve-VmfStoppedMachineState -Context ([pscustomobject]@{ Rg = 'rg'; VmName = 'vm1' })
            $r.MachineState | Should -Be 'restored'
            $r.Detail | Should -Match 'started again'
        }
    }

    It 'says CHANGED when it cannot, and says it does not run until a person starts it' {
        InModuleScope VmMigrationFactory {
            Mock Start-VmfVm { throw 'AllocationFailed' }
            $r = Resolve-VmfStoppedMachineState -Context ([pscustomobject]@{ Rg = 'rg'; VmName = 'vm1' })
            $r.MachineState | Should -Be 'changed' -Because 'a machine sitting powered off has certainly been changed'
            $r.Detail | Should -Match 'does not run until a person starts it'
            $r.Detail | Should -Match 'AllocationFailed'
        }
    }
}

Describe 'EVAL-H4/M1: the engine uses the derivation' {
    BeforeAll { $script:sm = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw }

    It 'no branch stamps untouched on every handler return any more' {
        $script:sm | Should -Not -Match "if \(\`$result\.Reason\) \{ \`$handlerStop\.ReasonCode = \[string\]\`$result\.Reason; \`$handlerStop\.MachineState = 'untouched' \}"
        $script:sm | Should -Match 'Get-VmfStateMutates -State \$state'
    }

    It 'the exhausted-attempts branch tries to put the power back before it reports' {
        $script:sm | Should -Match 'Resolve-VmfStoppedMachineState'
    }

    It 'a handler may state what it left behind' {
        $script:sm | Should -Match 'if \(\$result\.MachineState\)'
    }
}

Describe 'EVAL-M2: the fixer tolerates what its own checker calls normal' {
    BeforeAll {
        $script:fixer = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Set-NvmeReady.ps1') -Raw
        $script:checker = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Test-NvmeReady.ps1') -Raw
    }

    It 'guards the service key before writing to it' {
        $loop = [regex]::Match($script:fixer, "(?s)foreach \(\`$svc in @\('stornvme', 'pci', 'vpci'\)\).*?\n        \}").Value
        $loop | Should -Match 'Test-Path \$svcPath'
    }

    It 'reports a missing service as information, matching the checker' {
        $script:fixer | Should -Match "'INFO' 'not present on this image"
        # the checker's position, which the fixer contradicted
        $script:checker | Should -Match '(?i)vpci'
    }
}
