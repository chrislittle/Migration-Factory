#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EVAL-H1: the lease was 180 seconds while the engine performed single waits of
# up to 600. The wrapper renews before each ARM operation, but one call that
# polls internally is ONE operation - so nothing renewed during the longest
# waits, and the watchdog declared a healthy worker dead, wrote "reaped expired
# lease... VM will be resumed" about a worker that never died, and handed a
# mid-conversion machine to a second worker while the first was still inside an
# ARM poll on it. State documents have no lease check on write, so the
# abandoned worker's last transition can overwrite the new holder's.
#
# It fired on SUCCESSFUL conversions - a Windows first boot onto NVMe routinely
# takes longer than three minutes - and it hit STOPPED, SAFETY_PRISTINE and
# STARTING: the states in and around the deallocated window.
#
# These numbers are DERIVED from the source, so the next long wait somebody adds
# has to be reconciled with the lease rather than quietly contradicting it.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:azops = @(
        Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOps.ps1') -Raw
        Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1') -Raw
    )
    $script:startWave = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1') -Raw

    # every wait budget the azureops layer declares
    $script:waits = @(foreach ($t in $script:azops) {
        [regex]::Matches($t, '\$TimeoutSeconds\s*=\s*(\d+)') | ForEach-Object { [int]$_.Groups[1].Value }
    })
    $script:leaseDefault = [int]([regex]::Match($script:startWave, '\$LeaseTimeoutSeconds\s*=\s*(\d+)').Groups[1].Value)
}

Describe 'EVAL-H1: the lease outlives the longest thing the engine does' {
    It 'found the numbers to compare' {
        @($script:waits).Count | Should -BeGreaterThan 1
        $script:leaseDefault | Should -BeGreaterThan 0
    }

    It 'no single wait can outlast the lease that protects it' {
        $longest = ($script:waits | Measure-Object -Maximum).Maximum
        $script:leaseDefault | Should -BeGreaterThan $longest `
            -Because "a $longest-second wait under a $($script:leaseDefault)-second lease is the engine contradicting itself"
    }
}

Describe 'EVAL-H1: every long wait renews the lease while it waits' {
    It 'each polling loop ticks the heartbeat' {
        # A loop that sleeps without renewing is the exact defect: the wrapper
        # cannot help, because the whole wait is one operation.
        $offenders = foreach ($text in $script:azops) {
            foreach ($m in [regex]::Matches($text, '(?s)function\s+([A-Za-z-]+)\s*\{.*?(?=\nfunction |\z)')) {
                $name = $m.Groups[1].Value
                $body = $m.Value
                if ($body -notmatch 'Start-Sleep -Seconds \$PollIntervalSeconds') { continue }
                if ($body -notmatch 'VmfOpHeartbeat') { "$name sleeps without renewing the lease" }
            }
        }
        $offenders -join '; ' | Should -BeNullOrEmpty
    }

    It 'the heartbeat is throttled, so a fast loop does not hammer the store' {
        $sm = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        $sm | Should -Match 'TotalSeconds -ge 25'
    }
}

Describe 'EVAL-LAB-1: what the real-Azure drill found, so it cannot come back' {
    BeforeAll {
        $script:azAll = @(
            Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOps.ps1') -Raw
            Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1') -Raw
        ) -join "`n"
        $script:sm = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
    }

    It 'the power operations do NOT block, or the wait happens where no heartbeat is' {
        # THE defect the drill found. Stop-AzVM and Start-AzVM block until Azure
        # finishes, so all the waiting happened BEFORE the poll loop - and the
        # loop's very first iteration saw the machine already in state and
        # returned. The heartbeat two lines down was never reached, not once,
        # in a 44-second operation. Measured: zero renewals. The EVAL-H1 unit
        # test asserts the heartbeat is invoked IN the loop, and it is; the loop
        # was simply not where the time went.
        $script:azAll | Should -Match 'Stop-AzVM[^\r\n]*-NoWait'
        $script:azAll | Should -Match 'Start-AzVM[^\r\n]*-NoWait'
    }

    It 'a poll waiting FOR a state treats an unreadable one as "not yet", never as fatal' {
        # -NoWait means the machine is genuinely mid-transition when first
        # polled, and Azure sometimes reports no power-state code at all.
        # Get-VmfPowerState is right to throw - everywhere ELSE an unreadable
        # power state must not be guessed at - but inside a poll that is
        # waiting for a state, "cannot tell yet" is not a yes or a no, and the
        # timeout still ends it.
        foreach ($fn in 'Stop-VmfVmDeallocated', 'Start-VmfVm') {
            $body = [regex]::Match($script:azAll, "(?s)function $fn \{.*?\n\}").Value
            $body | Should -Match 'catch \{ \$state = \$null; \$lastPollError' -Because "$fn polls for a state"
        }
    }

    It 'and the timeout says what the last reading was, rather than only that it gave up' {
        $script:azAll | Should -Match 'Last power-state read said'
    }

    It 'the lease budget comfortably exceeds the heartbeat''s REAL renewal gap' {
        # Measured against Azure: the heartbeat is throttled to 25s but can only
        # fire when a poll comes round, so renewals land about 31 seconds apart.
        # The budget must clear that with room, or the lease lapses BETWEEN
        # renewals - which is a different bug wearing the same symptom.
        $throttle = [int]([regex]::Match($script:sm, '\.TotalSeconds -ge (\d+)').Groups[1].Value)
        $budget = [int]([regex]::Match(
            (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1') -Raw),
            '\$LeaseTimeoutSeconds = (\d+)').Groups[1].Value)
        $throttle | Should -BeGreaterThan 0
        $budget | Should -BeGreaterThan 0
        # A measured gap of ~31s against a 25s throttle: allow generously for
        # the poll cadence and still demand a large margin.
        $budget | Should -BeGreaterThan ($throttle * 4) `
            -Because "a $budget s lease against a $throttle s throttle leaves too little room for the poll cadence"
    }
}
