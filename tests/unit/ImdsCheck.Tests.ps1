#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# VERIFY-FP-1, part 1: the Instance Metadata Service, asked from inside the
# guest before and after the move. Scope set 2026-09-28
# (docs/backlog/verify-fp-1-...): fails a move only when IMDS answered before
# and does not after, or reports a size that is not the plan's target. A guest
# that never reached IMDS, or a script that could not run, never fails a move -
# every validation failure rolls back (FAIL-1), so this must not be flaky.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    function Global:ImR([string]$Reached, [string]$Size = '') { [pscustomobject]@{ reached = $Reached; vmSize = $Size } }
}
AfterAll { Remove-Item 'function:\ImR' -ErrorAction SilentlyContinue }

Describe 'VERIFY-FP-1: judging the reading after the move' {
    It '<Name>' -ForEach @(
        @{ Name = 'answered before, not after: fails'; B = 'yes'; A = 'no'; Size = ''; Ok = $false; Say = 'answered before the move and does not answer now' },
        @{ Name = 'never answered: passes'; B = 'no'; A = 'no'; Size = ''; Ok = $true; Say = 'does not stop the move' },
        @{ Name = 'no reading before, none after: passes'; B = 'unknown'; A = 'no'; Size = ''; Ok = $true; Say = 'does not stop the move' },
        @{ Name = 'the script could not run after: passes, and says so'; B = 'yes'; A = 'unknown'; Size = ''; Ok = $true; Say = 'could not ask' },
        @{ Name = 'answered on the target size: passes'; B = 'yes'; A = 'yes'; Size = 'Standard_D2s_v6'; Ok = $true; Say = 'size Standard_D2s_v6' },
        @{ Name = 'answered on another size: fails'; B = 'yes'; A = 'yes'; Size = 'Standard_D4s_v6'; Ok = $false; Say = 'reports the size Standard_D4s_v6' },
        @{ Name = 'another size fails even with no reading before'; B = 'unknown'; A = 'yes'; Size = 'Standard_D4s_v6'; Ok = $false; Say = 'target is Standard_D2s_v6' },
        @{ Name = 'the size is compared without case'; B = 'yes'; A = 'yes'; Size = 'standard_d2s_v6'; Ok = $true; Say = 'answered' }) {
        InModuleScope VmMigrationFactory -Parameters @{ b = $B; a = $A; size = $Size; ok = $Ok; say = $Say } {
            $r = Test-VmfImdsOutcome -Before (Global:ImR $b) -After (Global:ImR $a $size) -TargetSize 'Standard_D2s_v6'
            $r.Ok | Should -Be $ok
            $r.Detail | Should -Match $say
        }
    }

    It 'no reading at all is not a failure' {
        InModuleScope VmMigrationFactory { (Test-VmfImdsOutcome -Before $null -After $null -TargetSize 'x').Ok | Should -BeTrue }
    }
}

Describe 'IMDS-KEEP-2: the reading before the move is the first one, taken on the untouched machine' {
    # IMDS-KEEP-1 kept a known reading over an unknown one and let a newer
    # known reading replace it. Since 2026-10-09, the baseline is the FIRST
    # reading of the attempt, taken before any guest change - like guestBefore.
    # The example: the network works before the move ("yes"); the preparation
    # breaks it; the retried GUEST_PREP reads "no"; that "no" replaced the
    # "yes", and the check after the move compared "no" with "no" and passed a
    # machine the product broke. "Changed" is the audit trail's own answer
    # (Test-VmfGuestChangedThisAttempt), passed in.
    It '<Name>' -ForEach @(
        @{ Name = 'yes, then unknown: yes is kept'; E = 'yes'; L = 'unknown'; C = $false; Want = 'yes'; Keep = 'earlier'; Why = 'kept' },
        @{ Name = 'no, then unknown: no is kept'; E = 'no'; L = 'unknown'; C = $false; Want = 'no'; Keep = 'earlier'; Why = 'kept' },
        @{ Name = 'yes, then no before any change: yes is kept'; E = 'yes'; L = 'no'; C = $false; Want = 'yes'; Keep = 'earlier'; Why = 'kept' },
        @{ Name = 'yes, then no after a guest change: yes is kept (the example above)'; E = 'yes'; L = 'no'; C = $true; Want = 'yes'; Keep = 'earlier'; Why = 'kept' },
        @{ Name = 'no, then yes after a guest change: no is kept'; E = 'no'; L = 'yes'; C = $true; Want = 'no'; Keep = 'earlier'; Why = 'kept' },
        @{ Name = 'no, then yes before any change: no is kept'; E = 'no'; L = 'yes'; C = $false; Want = 'no'; Keep = 'earlier'; Why = 'kept' },
        @{ Name = 'unknown, then yes before any change: yes'; E = 'unknown'; L = 'yes'; C = $false; Want = 'yes'; Keep = 'latest'; Why = 'replacedUnknown' },
        @{ Name = 'unknown, then no before any change: no'; E = 'unknown'; L = 'no'; C = $false; Want = 'no'; Keep = 'latest'; Why = 'replacedUnknown' },
        @{ Name = 'unknown, then yes after a guest change: stays unknown'; E = 'unknown'; L = 'yes'; C = $true; Want = 'unknown'; Keep = 'earlier'; Why = 'changed' },
        @{ Name = 'unknown, then no after a guest change: stays unknown'; E = 'unknown'; L = 'no'; C = $true; Want = 'unknown'; Keep = 'earlier'; Why = 'changed' },
        @{ Name = 'unknown, then unknown before any change: unknown'; E = 'unknown'; L = 'unknown'; C = $false; Want = 'unknown'; Keep = 'latest'; Why = 'replacedUnknown' }) {
        InModuleScope VmMigrationFactory -Parameters @{ e = $E; l = $L; c = $C; want = $Want; keep = $Keep; why = $Why } {
            $earlier = Global:ImR $e 'Standard_D2s_v4'
            $latest = Global:ImR $l 'Standard_D2s_v4'
            $r = Select-VmfImdsBefore -Earlier $earlier -Latest $latest -GuestChanged $c
            [string]$r.Reading.reached | Should -Be $want
            $r.Why | Should -Be $why
            $r.KeptEarlier | Should -Be ($keep -eq 'earlier')
            # The kept one is the earlier OBJECT, with its own time and size -
            # never the new reading relabelled.
            if ($keep -eq 'earlier') { [object]::ReferenceEquals($r.Reading, $earlier) | Should -BeTrue }
            else { [object]::ReferenceEquals($r.Reading, $latest) | Should -BeTrue }
        }
    }

    It 'the first reading of an attempt, on the untouched machine, is taken as it is (<L>)' -ForEach @(@{ L = 'yes' }, @{ L = 'no' }, @{ L = 'unknown' }) {
        InModuleScope VmMigrationFactory -Parameters @{ l = $L } {
            $latest = Global:ImR $l
            $r = Select-VmfImdsBefore -Earlier $null -Latest $latest -GuestChanged $false
            [object]::ReferenceEquals($r.Reading, $latest) | Should -BeTrue
            $r.KeptEarlier | Should -BeFalse
            $r.Why | Should -Be 'first'
        }
    }

    It 'no reading on record and the guest already changed: a known answer now is not taken, the reading is unknown (<L>)' -ForEach @(@{ L = 'yes' }, @{ L = 'no' }) {
        # Not expected - GUEST_PREP asks before its first change - but if a
        # document has no reading and the audit trail shows a change, an
        # answer now cannot show the machine before it.
        InModuleScope VmMigrationFactory -Parameters @{ l = $L } {
            $latest = [pscustomobject]@{ reached = $l; vmSize = 'Standard_D2s_v4'; securityType = 'TrustedLaunch'; secureBoot = 'true'; vtpm = 'true'; readUtc = '2026-10-09T10:00:00.0000000Z' }
            $r = Select-VmfImdsBefore -Earlier $null -Latest $latest -GuestChanged $true
            [string]$r.Reading.reached | Should -Be 'unknown'
            [string]$r.Reading.vmSize | Should -BeNullOrEmpty
            [string]$r.Reading.securityType | Should -BeNullOrEmpty
            [object]::ReferenceEquals($r.Reading, $latest) | Should -BeFalse
            [string]$latest.reached | Should -Be $l -Because 'the new reading itself is never relabelled'
            $r.Why | Should -Be 'changed'
        }
    }

    It 'an earlier reading with no answer field is not known: before any change the new one is taken' {
        InModuleScope VmMigrationFactory {
            $latest = Global:ImR 'yes'
            $r = Select-VmfImdsBefore -Earlier ([pscustomobject]@{ vmSize = 'x' }) -Latest $latest -GuestChanged $false
            [object]::ReferenceEquals($r.Reading, $latest) | Should -BeTrue
        }
    }
}
Describe 'VERIFY-FP-1: reading the guest' {
    BeforeAll {
        $script:ctx = { param($os) @{ Plan = [pscustomobject]@{ assessment = [pscustomobject]@{ os = $os } }; Rg = 'rg'; VmName = 'vm'; VmId = '/vm'; RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-no-store') } }
    }

    It 'asks the script for the machine''s OS, and maps its facts' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            [pscustomobject]@{ result = 'READY'; facts = [pscustomobject]@{ imdsReached = 'yes'; imdsVmSize = 'Standard_D2s_v6'; imdsSecurityType = 'TrustedLaunch'; imdsSecureBoot = 'true'; imdsVtpm = 'true' } }
        }
        InModuleScope VmMigrationFactory -Parameters @{ c = (& $script:ctx 'Windows') } {
            $r = Get-VmfImdsReading -Context $c
            $r.reached | Should -Be 'yes'
            $r.vmSize | Should -Be 'Standard_D2s_v6'
            $r.securityType | Should -Be 'TrustedLaunch'
            $r.secureBoot | Should -Be 'true'
        }
        Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm -ParameterFilter { $ScriptName -eq 'Test-Imds.ps1' } -Times 1 -Exactly
    }

    It 'a lost lease is not read as unknown: it reaches the state machine, which abandons the machine' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { throw 'lease lost for /vm - abandon this VM.' }
        InModuleScope VmMigrationFactory -Parameters @{ c = (& $script:ctx 'Linux') } {
            { Get-VmfImdsReading -Context $c } | Should -Throw '*abandon this VM*'
        }
    }

    It 'a script that says BLOCKED, fails, or reports nothing is unknown - never no' -ForEach @(
        @{ Out = { [pscustomobject]@{ result = 'BLOCKED'; facts = [pscustomobject]@{ imdsReached = 'no' } } } },
        @{ Out = { throw 'RunCommand failed' } },
        @{ Out = { [pscustomobject]@{ result = 'READY'; facts = [pscustomobject]@{} } } }) {
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm $Out
        InModuleScope VmMigrationFactory -Parameters @{ c = (& $script:ctx 'Linux') } {
            (Get-VmfImdsReading -Context $c).reached | Should -Be 'unknown'
        }
    }
}

Describe 'VERIFY-FP-1: the guest scripts' {
    It '<Name> is in the manifest, sends the header, never goes through a proxy, and asks a version that has securityType' -ForEach @(
        @{ Name = 'Test-Imds.ps1'; Os = 'windows'; NoProxy = '\$req\.Proxy = \$null'; Header = "Headers\.Add\('Metadata', 'true'\)" },
        @{ Name = 'imds-check.sh'; Os = 'linux'; NoProxy = "--noproxy '\*'"; Header = "-H 'Metadata: true'" }) {
        $manifest = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'manifest.json') -Raw | ConvertFrom-Json
        @($manifest.scripts | Where-Object name -EQ $Name).Count | Should -Be 1
        # Code only: both scripts name the service and its address in comments.
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'guest' $Os $Name)
        $code | Should -Match $NoProxy
        $code | Should -Match $Header
        $code | Should -Match '169\.254\.169\.254/metadata/instance/compute\?api-version=2023-07-01'
        $code | Should -Match 'vmf\.guest/3'
        $code | Should -Match '70'
    }

    It 'the Windows script runs under Windows PowerShell 5.1: no -NoProxy, ternary or null-coalescing' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Test-Imds.ps1')
        $code | Should -Not -Match '-NoProxy'
        $code | Should -Not -Match '\?\?'
        $code | Should -Not -Match '\s\?\s[^:]+\s:\s'
    }

    It 'the facts it reports are declared in the contract' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json') -Raw | ConvertFrom-Json
        $declared = $schema.properties.facts.properties.PSObject.Properties.Name
        foreach ($f in 'imdsReached', 'imdsVmSize', 'imdsSecurityType', 'imdsSecureBoot', 'imdsVtpm') { $declared | Should -Contain $f }
    }
}
