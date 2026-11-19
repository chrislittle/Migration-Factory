#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# MANUAL-REVIEW-1, area C: the words a person reads on the run pages that
# come from the engine - the step lines of the Activity list, the timeline of
# a machine, the Why it stopped box and the messages of a refusal.
#
# The rules (2026-11-12): a line a 1.0 install cannot show is removed;
# every other line is a sentence in ASD-STE100, with the product's own nouns
# and Azure's own names. These checks hold the forms that have a shape:
#   - no engine word in capital letters (BLOCKED, FAILED, AND, STOPPED,
#     COULD NOT) and no state name (CONVERTING) in the words of a stop;
#   - no "(s)" plural, no "size@region" code, no "reservation" alone;
#   - no stop for a feature that was never built (bootableClone), and one
#     guard - policyNotKnown - for a plan that does not ask for the first
#     safety copy;
#   - no line about a lab run in what the plan or the targets step shows.
# tests/js/manual-review-run-pages.test.js holds the page side.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $mod = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
    # The engine files that write step lines and stops, and the three public
    # files whose lines the Activity list shows for a wave.
    $script:files = @(Get-ChildItem -Path (Join-Path $mod 'Private' 'engine') -Filter '*.ps1' -File) +
        @(Get-Item (Join-Path $mod 'Public' 'Start-VmfWave.ps1'), (Join-Path $mod 'Public' 'New-VmfWaveReservation.ps1'),
            (Join-Path $mod 'Public' 'Invoke-VmfWaveCloseOut.ps1'))
    $script:code = @{}
    foreach ($f in $script:files) { $script:code[$f.Name] = Get-VmfCodeOnly -Path $f.FullName }

    # Each string literal of the code, with the name of its file.
    $script:literals = foreach ($f in $script:files) {
        $tokens = $null; $errs = $null
        [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs) | Out-Null
        foreach ($tk in $tokens) {
            if ($tk.Kind -in @('StringExpandable', 'StringLiteral', 'HereStringExpandable', 'HereStringLiteral')) {
                [pscustomobject]@{ File = $f.Name; Line = $tk.Extent.StartLineNumber; Text = $tk.Text }
            }
        }
    }
    function Global:Find-MrcLiteral([string]$Pattern, [switch]$CaseSensitive) {
        @($script:literals | Where-Object {
                if ($CaseSensitive) { $_.Text -cmatch $Pattern } else { $_.Text -match $Pattern } } |
            ForEach-Object { "$($_.File):$($_.Line) $($_.Text)" })
    }
}

Describe 'MANUAL-REVIEW-1: engine lines are sentences' {
    It 'no line says BLOCKED, FAILED, COULD NOT, STILL HELD or STOPPED in capital letters' {
        Find-MrcLiteral -CaseSensitive '\b(BLOCKED|FAILED|COULD NOT|STILL HELD|STOPPED|DOWN)\b(?!_)(?=[\s:.,)])' |
            Where-Object { $_ -notmatch "-eq 'BLOCKED'|'BLOCKED'\s*\)|\bresult\b" } |
            Should -BeNullOrEmpty -Because 'a person reads these words in the timeline and in Why it stopped'
    }

    It 'no line joins two clauses with a capital AND' {
        Find-MrcLiteral -CaseSensitive '\bAND\b' | Should -BeNullOrEmpty
    }

    It 'no stop names the state of the engine in place of the step a page shows' {
        Find-MrcLiteral '"\$state failed' | Should -BeNullOrEmpty
        $script:code['StateMachine.ps1'] | Should -Match '\$stepWord = Get-VmfStepWord -State \$state'
    }

    It 'the step word is the name the pages show' {
        InModuleScope VmMigrationFactory {
            Get-VmfStepWord -State 'CONVERTING' | Should -Be 'Moving'
            Get-VmfStepWord -State 'VALIDATING' | Should -Be 'Verifying'
            Get-VmfStepWord -State 'PRECHECK' | Should -Be 'Checking'
            Get-VmfRearmWords -From 'GUEST_PREP' | Should -Be 'The next attempt starts again at Preparing. Earlier attempts are not counted against it.'
        }
    }

    It 'no line has a "(s)" plural' {
        Find-MrcLiteral '\w\(s\)' | Should -BeNullOrEmpty -Because 'a count says one machine or two machines'
    }

    It 'no line names a size as size@region' {
        Find-MrcLiteral '\)@\$\(' | Should -BeNullOrEmpty
    }

    It 'no line says "reservation" alone, or "capacity reservation" without on-demand' {
        # Azure's name is on-demand capacity reservation; a capacity reservation
        # group is Azure's name for the group, and a name in code is no word.
        $bad = foreach ($l in $script:literals) {
            if ($l.Text -notmatch '\s') { continue }
            $t = $l.Text -replace '(?i)on-demand capacity reservations?', '' -replace '(?i)capacity reservation groups?', ''
            $t = $t -replace '\$\([^)]*\)', '' -replace '\$\w+', ''
            if ($t -match '(?i)\breservations?\b') { "$($l.File):$($l.Line) $($l.Text)" }
        }
        # The two files of a wave's capacity lines are held to it here. Other
        # engine files are not held to it yet.
        @($bad | Where-Object { $_ -match '^(New-VmfWaveReservation|Invoke-VmfWaveCloseOut)\.ps1' }) | Should -BeNullOrEmpty
    }

    It 'the guest preparation stops say what did not finish' {
        Find-MrcLiteral 'Found on D:' | Should -BeNullOrEmpty
        $script:code['StateMachine.ps1'] | Should -Match 'The temporary disk D: contains these files and folders: '
        $script:code['StateMachine.ps1'] | Should -Match 'The check of the temporary disk inside the machine did not finish: '
        $script:code['StateMachine.ps1'] | Should -Match 'The move of the Windows page file off the temporary disk did not finish: '
    }

    It 'a refused stop of the machine says what Azure did, in the product nouns' {
        Find-MrcLiteral 'restarted untouched|Deallocation failed' | Should -BeNullOrEmpty
        $script:code['StateMachine.ps1'] | Should -Match 'Azure did not stop the machine: \$err The product started the machine again\. Nothing on the machine changed\.'
    }

    It 'a step the engine tries again says the attempt as a sentence' {
        Find-MrcLiteral 'attempt \$attempts/' | Should -BeNullOrEmpty
        $script:code['StateMachine.ps1'] | Should -Match '"Attempt \$attempts of \$max failed: \$err"'
    }

    It 'a refused on-demand capacity reservation names its size and region in words' {
        $script:code['New-VmfWaveReservation.ps1'] | Should -Match 'Azure did not make the on-demand capacity reservation of \$\(\$claim\.size\) in \$\(\$claim\.region\): \$said'
    }

    It 'a power state is said by the name the portal shows, never as a PowerState code' {
        # The power state read from Azure ($power); a guard against a caller's
        # wrong argument ($Power) is a programming error, not an operator line.
        Find-MrcLiteral -CaseSensitive "\(\`$power\)|'\`$power'" | Should -BeNullOrEmpty
        InModuleScope VmMigrationFactory {
            Get-VmfPowerStateName -Power 'PowerState/starting' | Should -Be 'Starting'
            Get-VmfPowerStateName -Power 'PowerState/deallocating' | Should -Be 'Deallocating'
            Get-VmfPowerStateName -Power 'PowerState/unknownthing' | Should -Not -Match 'PowerState/'
        }
    }

    It 'the two Backing up steps say which copy, so a stop names one step' {
        InModuleScope VmMigrationFactory {
            Get-VmfStepWord -State 'SAFETY_PRISTINE' | Should -Not -Be (Get-VmfStepWord -State 'SAFETY_COPY')
        }
    }

    It 'no line names a control that does not exist, or an opinion of a version' {
        Find-MrcLiteral 'Start this machine again' | Should -BeNullOrEmpty -Because 'the button is Try this machine again'
        Find-MrcLiteral '\bolder than the minimum\b' | Should -BeNullOrEmpty
        Find-MrcLiteral 'group has a reservation' | Should -BeNullOrEmpty
    }

    It 'a reservation Azure did not release sends the person to Release where Release can find it' {
        Find-MrcLiteral 'Release them by hand' | Should -BeNullOrEmpty -Because 'rule 12: the app has Release on the wave'
        # MANUAL-REVIEW-1 review: a quota record that another operation changed
        # is RELEASED or gone, so Release does not find what Azure made. That
        # one line says so, and names where to find it in Azure.
        $code = $script:code['New-VmfWaveReservation.ps1']
        $code | Should -Match 'The product has no record of it, so Release on the wave does not find it\. '
        $code | Should -Match 'with the tag vmfCapacityReservation=true\.'
        @([regex]::Matches($code, 'Delete it in Azure')).Count | Should -Be 1 -Because 'every other failed release has a record that Release finds'
    }
}

Describe 'MANUAL-REVIEW-1: stops a 1.0 install cannot show are gone' {
    It 'no bootableClone: no default, no stop, no contract field' {
        foreach ($f in $script:files) { $script:code[$f.Name] | Should -Not -Match 'bootableClone' -Because $f.Name }
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json
        $schema.properties.policy.properties.PSObject.Properties.Name | Should -Not -Contain 'bootableClone'
        InModuleScope VmMigrationFactory { (Get-VmfStoredPolicyValues).Keys | Should -Not -Contain 'bootableClone' }
        # MANUAL-REVIEW-1 review: and no document describes it as if it were there.
        # PUBLIC-SYNC-1: the traceability map does not ship to the public repository.
        $docs = @(@('docs', 'architecture', 'architecture.html'), @('docs', 'ms-guide-traceability.md')).Where({
                $_[1] -ne 'ms-guide-traceability.md' -or (Test-Path (Join-Path $script:repoRoot @_)) })
        foreach ($doc in $docs) {
            $text = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot @doc))
            $text | Should -Not -Match 'bootableClone' -Because ($doc -join '/')
        }
    }

    It 'a step that failed after its attempts ends its words with a period' {
        $script:code['StateMachine.ps1'] | Should -Match ([regex]::Escape("step failed after `$attempts attempts: `$err`$extra`" -replace '(?<![.!?])`$', '.')"))
        Find-MrcLiteral 'pristine copy already taken' | Should -BeNullOrEmpty
    }

    It 'close-out says what Azure did, not what it bills' {
        $script:code['Invoke-VmfWaveCloseOut.ps1'] | Should -Match 'Azure accepted the release\.'
        $script:code['Invoke-VmfWaveCloseOut.ps1'] | Should -Not -Match 'stopped the charge'
    }

    It 'no stop reason without a stop: bootableCloneNotImplemented and safetyCopyNotPristine are gone' {
        $codes = @((Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons.code)
        $codes | Should -Not -Contain 'bootableCloneNotImplemented'
        $codes | Should -Not -Contain 'safetyCopyNotPristine'
        $codes | Should -Contain 'policyNotKnown'
    }

    It 'one guard, policyNotKnown, refuses a plan that does not ask for the first safety copy' {
        InModuleScope VmMigrationFactory {
            Get-Command Get-VmfSafetyCopyRefusal -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            $entry = [pscustomobject]@{ vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
                policy = [pscustomobject]@{ safetyCopy = 'clean' } }
            Get-VmfPlanPolicyRefusal -PlanEntry $entry | Should -Match "'safetyCopy' to 'clean'"
            $entry.policy.safetyCopy = 'pristine'
            Get-VmfPlanPolicyRefusal -PlanEntry $entry | Should -BeNullOrEmpty
            $entry.policy = [pscustomobject]@{}
            Get-VmfPlanPolicyRefusal -PlanEntry $entry | Should -BeNullOrEmpty
        }
    }

    It 'the wave acceptance refuses the same plan with the one guard' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Confirm-VmfWaveOptions.ps1')
        $code | Should -Not -Match 'does not ask for the first safety copy'
        $code | Should -Match 'Get-VmfPlanPolicyRefusal -PlanEntry'
    }

    It 'no plan note about a lab run' {
        InModuleScope VmMigrationFactory {
            Get-Command Get-VmfNvmeSourceNote -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
            $a = [pscustomobject]@{ sourceSize = 'Standard_E2bs_v5'; diskController = 'NVMe' }
            @(Get-VmfPlanEntryNotes -Mapping @{ Target = 'Standard_E2bds_v6'; Reason = '' } -Assessment $a -Controller 'NVMe' -Path 'A') -join ' ' |
                Should -Not -Match '(?i)\blab\b'
        }
    }
}
