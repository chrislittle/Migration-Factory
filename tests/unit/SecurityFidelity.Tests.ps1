#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TRUST-1: the security posture must survive the migration, proven not assumed.
#
# The defect this closes was found by the owner asking "have we done anything
# with trusted launch?" - and the traced answer was no, four times over:
# discovery read securityType and nothing ever read it again; the capture
# carried no securityProfile; the rebuild set none; validation never compared.
# Path B deletes the machine definition and rebuilds it from the capture, so a
# Trusted Launch machine's secure boot and vTPM rode entirely on the platform
# default, and whatever came out passed.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Script:Fidelity($cap, $live) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $cap; l = $live } {
            Test-VmfSecurityFidelity -Captured $c -Live $l
        }
    }
    function Script:TL([bool]$sb = $true, [bool]$vtpm = $true) {
        [pscustomobject]@{ securityType = 'TrustedLaunch'; secureBootEnabled = $sb; vTpmEnabled = $vtpm }
    }
}

Describe 'TRUST-1: the fidelity verdict' {
    It 'a preserved Trusted Launch posture passes' {
        $v = Script:Fidelity (Script:TL) (Script:TL)
        $v.Ok | Should -BeTrue
        $v.Verdict | Should -Be 'MATCH'
    }

    It 'Trusted Launch silently becoming Standard FAILS - the original defect' {
        $v = Script:Fidelity (Script:TL) ([pscustomobject]@{ securityType = 'Standard' })
        $v.Ok | Should -BeFalse
        $v.Detail | Should -Match 'TrustedLaunch'
        $v.Detail | Should -Match 'Standard'
    }

    It 'a live machine with NO security profile at all reads as Standard, and fails against a TL capture' {
        $v = Script:Fidelity (Script:TL) $null
        $v.Ok | Should -BeFalse -Because 'absence of the profile IS the downgrade'
    }

    It 'a Standard machine silently UPGRADED fails too - a change nobody approved is a change' {
        $v = Script:Fidelity ([pscustomobject]@{ securityType = 'Standard' }) (Script:TL)
        $v.Ok | Should -BeFalse
    }

    It 'the label matching is not enough: a flipped secure-boot flag fails' {
        $v = Script:Fidelity (Script:TL -sb $true) (Script:TL -sb $false)
        $v.Ok | Should -BeFalse
        $v.Detail | Should -Match 'secure boot'
    }

    It 'and so does a flipped vTPM flag' {
        $v = Script:Fidelity (Script:TL -vtpm $true) (Script:TL -vtpm $false)
        $v.Ok | Should -BeFalse
        $v.Detail | Should -Match 'vTPM'
    }

    It 'a capture from before the field existed is UNKNOWN - never a pass, never a fail' {
        # The DRIVER-1 rule. Machines migrated before TRUST-1 have no captured
        # posture; failing them would manufacture regressions, passing them
        # would claim proof that does not exist.
        $v = Script:Fidelity $null (Script:TL)
        $v.Ok | Should -BeTrue -Because 'it must not fail the machine'
        $v.Verdict | Should -Be 'UNKNOWN'
        $v.Detail | Should -Match 'nothing to compare'
    }

    It 'an empty captured securityType is treated as Standard, both sides' {
        $v = Script:Fidelity ([pscustomobject]@{ securityType = '' }) $null
        $v.Ok | Should -BeTrue
        $v.Verdict | Should -Be 'MATCH'
    }
}

Describe 'TRUST-1: the capture carries the posture' {
    # UX-STUCK-1's lesson made structural: the unit tests for the rebuild pass
    # a fixture, and a fixture can invent fields the capture never writes -
    # which is exactly how `skuName` was missing for a week. So derive the
    # field list from the capture SOURCE and require what the rebuild and the
    # validator READ to be a subset of what the capture WRITES.
    BeforeAll {
        $script:azops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOps.ps1') -Raw
        $script:captureFn = [regex]::Match($script:azops, '(?s)function Get-VmfVmCapture.*?\n\}').Value
    }

    It 'the capture writes securityProfile with all four facts' {
        foreach ($f in 'securityType', 'secureBootEnabled', 'vTpmEnabled', 'encryptionAtHost') {
            $script:captureFn | Should -Match $f
        }
    }

    It 'a machine with no SecurityProfile captures $null, not an invented object' {
        # Old VMs and some paths return no profile; the capture must record
        # "none", because $null is what lets the validator say UNKNOWN
        # honestly instead of comparing against fabricated defaults.
        $script:captureFn | Should -Match 'if \(\$Vm\.SecurityProfile\)'
        $script:captureFn | Should -Match '\} else \{ \$null \}'
    }
}

# REBUILD-REMOVE-ROLE-1: the rebuild's create (New-VmfVmFromCapture) is gone, and with it
# the tests that it set the posture again. The capture and the comparison stay.

Describe 'TRUST-1: assessment blocks what the tool cannot carry' {
    BeforeAll {
        $script:rules = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Rules.ps1') -Raw
    }

    It 'a Confidential VM is BLOCKED at assessment, with the reason named' {
        $script:rules | Should -Match "confidential-vm-requires-manual"
        $script:rules | Should -Match "securityType -eq 'ConfidentialVM'"
    }

    It 'Trusted Launch is NOT blocked - it flows through and is preserved' {
        # The point of TRUST-1 is carrying it faithfully, not refusing it.
        $script:rules | Should -Not -Match "'TrustedLaunch'\)[^\r\n]*blocker"
    }
}

Describe 'TRUST-1: validation compares, on every path' {
    BeforeAll {
        $script:sm = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        $script:validating = [regex]::Match($script:sm, '(?s)function Invoke-VmfStepValidating.*?\n\}').Value
    }

    It 'VALIDATING reads the live posture and compares it to the capture' {
        $script:validating | Should -Match 'Test-VmfSecurityFidelity'
        $script:validating | Should -Match 'getSecurityProfile'
    }

    It 'a mismatch THROWS, which under FAIL-1 means the machine is put back' {
        $script:validating | Should -Match 'The check of the security settings failed'
    }

    It 'UNKNOWN is surfaced as a warning, not silently swallowed' {
        $script:validating | Should -Match "Verdict -eq 'UNKNOWN'"
    }
}
