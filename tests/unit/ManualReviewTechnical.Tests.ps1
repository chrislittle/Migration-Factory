#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MANUAL-REVIEW-1, area B: the understand, technical and reference pages, and
# the stop reasons, said against the code.
#
# Since 2026-11-12, the review must catch such faults for certain. Each
# test below holds one fact the review found false or unreachable in a shipped
# sentence, with the code that settles it named beside it. The wording rules
# that have a shape (a bare "reservation", a lab word or a region) are in the
# shared gate, tools/Test-SimplifiedEnglish.ps1 and tools/ste-terms.json.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:manual = Join-Path $script:repoRoot 'docs' 'manual'
    $script:stops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
    $script:stop = { param($Code) @($script:stops.reasons | Where-Object code -EQ $Code)[0] }
    $script:words = { param($Code) $r = & $script:stop $Code; "$($r.title) $($r.meaning) $($r.whatToDo)" }
    $script:page = { param($Rel) Get-Content (Join-Path $script:manual $Rel) -Raw }
}

Describe 'MANUAL-REVIEW-1: each stop reason says what the engine does' {

    It 'no rollback deletes the definition of a machine (REBUILD-REMOVE-1: no virtualMachines/delete in rbac-actions.json)' {
        & $script:words 'rollbackFailed' | Should -Not -Match '(?i)definition'
        $rbac = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        @($rbac.operations | ForEach-Object { @($_.actions) }) | Should -Not -Contain 'Microsoft.Compute/virtualMachines/delete'
    }

    It 'a lost storage volume is not blamed on a detach: the move resizes (Invoke-VmfStepConverting)' {
        & $script:words 'storageVolumesLost' | Should -Not -Match '(?i)detach'
        & $script:words 'storageVolumesLost' | Should -Not -Match '(?i)the data is safe'
    }

    It 'a subscription the engine cannot change to is not a wave run from another subscription (StateMachine.ps1, Use-VmfSubscriptionContext)' {
        $r = & $script:stop 'subscriptionNotReachable'
        $r.title | Should -Not -Match '(?i)different subscription|signed in'
        $r.whatToDo | Should -Not -Match '(?i)run this wave'
        $r.whatToDo | Should -Match 'give Assess and migrate on the subscription of this machine'
        # A disabled subscription has its own stop, subscriptionReadOnly.
        $r.whatToDo | Should -Not -Match '(?i)reactivate|disabled'
    }

    It 'no capacity stop sends a person to another zone: the product never changes the zone of a machine' {
        & $script:words 'capacityUnavailable' | Should -Not -Match '(?i)another zone'
        (& $script:stop 'capacityUnavailable').whatToDo | Should -Match 'On-demand capacity reservation for this wave to Yes, then select Reserve capacity'
    }

    It 'the MANA hosts include Bsv2 (Test-VmfTargetMayUseMana), and the title states the kernel fact, not an opinion' {
        $r = & $script:stop 'driverBelowFloor'
        $r.meaning | Should -Match 'Intel v5 and Bsv2 hosts'
        $r.title | Should -Not -Match '(?i)\bolder\b'
        $r.title | Should -Match 'minimum that Microsoft lists for MANA'
    }

    It 'a failed MANA driver install stops the move before the size changes (GUEST_PREP, FAILED_NEEDS_ATTENTION)' {
        $r = & $script:stop 'manaDriverInstallFailed'
        $r.meaning | Should -Not -Match '(?i)slower|NetVSC'
        $r.meaning | Should -Match 'stops before the size changes'
    }

    It 'Stop and ask does not move a machine without the kernel update (AN-PROCEED-NETVSC-1)' {
        (& $script:stop 'kernelUpdateFailed').whatToDo | Should -Not -Match '(?i)without the update'
    }

    It 'no stop text tells a lab story, and none says conversion or come up' {
        foreach ($r in $script:stops.reasons) {
            "$($r.title) $($r.meaning) $($r.whatToDo)" | Should -Not -Match '(?i)nobody measured|passing glitch|come up|\bconversion\b|holding the machine open|switched off|rebuild' -Because $r.code
        }
        $script:stops.retryLines.unlikely | Should -Not -Match '(?i)usually'
    }

    It 'the boot diagnostics are read when Azure gives them - the capture is best effort (StateMachine.ps1, Get-VmfBootDiagnostics)' {
        (& $script:stop 'bootFailedAfterConversion').meaning | Should -Match 'when Azure gives them'
    }

    It 'Disk Encryption unknown is said as unknown, with no story about what would have happened' {
        $r = & $script:stop 'diskEncryptionUnknown'
        $r.title | Should -Not -Match '(?i)could not be asked'
        $r.meaning | Should -Match 'Unknown is not the same as no encryption'
    }
}

Describe 'MANUAL-REVIEW-1: the decisions of 2026-11-13' {

    It 'each permission stop links the role to the access the Admin page offers, and still says only what is needed' {
        foreach ($code in 'permissionsMissing', 'permissionMissingNetwork', 'permissionMissingNetworkInterface', 'permissionMissingDiskEncryptionSet',
                          'permissionMissingIdentity', 'permissionMissingReservationGroup', 'permissionRefused') {
            $r = & $script:stop $code
            $r.whatToDo | Should -Match 'The access Assess and migrate gives (this|the VMF Migration) role\.' -Because $code
            $r.whatToDo | Should -Not -Match '(?i)Admin page|Azure portal' -Because $code
        }
    }

    It 'the on-demand capacity reservation bills until every machine has ended and the product releases it (Invoke-VmfWaveCloseOut.ps1)' {
        foreach ($rel in 'reference/costs.md', 'reference/wave-settings.md', 'understand/words.md') {
            $text = & $script:page $rel
            $text | Should -Match 'until every machine of the wave has ended and the product releases it, or until you select Release' -Because $rel
            $text | Should -Not -Match '(?i)until the wave finishes' -Because $rel
        }
    }

    It 'the setting is named On-demand capacity reservation for this wave' {
        # reference/wave-settings.md follows the label in waves.js (WaveWords.Tests.ps1), which builder C renames.
        & $script:page 'reference/before-a-machine-moves.md' | Should -Not -Match '(?<!On-demand )Capacity reservation for this wave'
        (& $script:stop 'capacityUnavailable').whatToDo | Should -Match 'set On-demand capacity reservation for this wave to Yes'
    }
}

Describe 'MANUAL-REVIEW-1: the understand, technical and reference pages say what the code does' {

    It 'every v7 size can give MANA, so no move keeps accelerated networking off on v7 (Test-VmfTargetNeedsManaDriver)' {
        & $script:page 'reference/before-a-machine-moves.md' | Should -Not -Match '(?i)such as a v7 size'
    }

    It 'the count of the checks is the count of the rows' {
        & $script:page 'reference/before-a-machine-moves.md' | Should -Not -Match '(?i)four checks'
    }

    It 'no restore, finish or rollback leaves a machine with no definition in Azure' {
        & $script:page 'understand/safety-copies.md' | Should -Not -Match '(?i)no definition in Azure'
        & $script:page 'technical/security.md' | Should -Not -Match '(?i)no definition in Azure'
    }

    It 'the product cannot read role assignments or Key Vault (rbac-actions.json has neither action)' {
        $text = & $script:page 'technical/security.md'
        $text | Should -Not -Match '(?i)can see Azure role assignments'
        $rbac = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        @($rbac.operations | ForEach-Object { @($_.actions) }) | Should -Not -Contain 'Microsoft.Authorization/roleAssignments/read'
    }

    It 'no page tells a pre-1.0 history with a date' {
        & $script:page 'technical/security.md' | Should -Not -Match '2026-09-11'
        & $script:page 'technical/the-perimeter.md' | Should -Not -Match '(?i)was in the perimeter for a time'
    }

    It 'the engine runs for every operation, not only for a wave (docker/entrypoint.ps1)' {
        & $script:page 'understand/words.md' | Should -Not -Match '(?i)only while a wave runs'
        $entry = Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw
        $entry | Should -Match "'assess'"
    }

    It 'the roles of the product identities are the ones the template grants (infra/platform.bicep, CODE-CONTAINER-WRITE-1)' {
        $bicep = Get-Content (Join-Path $script:repoRoot 'infra' 'platform.bicep') -Raw
        foreach ($rel in 'technical/run-store.md') {
            $text = & $script:page $rel
            foreach ($role in 'Storage Blob Data Owner', 'Storage Blob Data Reader', 'Storage Queue Data Contributor', 'Storage Table Data Contributor') {
                $text | Should -Match ([regex]::Escape($role)) -Because $rel
            }
        }
        foreach ($var in 'roleBlobOwner', 'roleBlobReader', 'roleQueueContributor', 'roleTableContributor', 'roleAcrPull', 'roleContributor', 'roleReader') {
            $bicep | Should -Match "roleDefinitionIdOrName: $var\b"
        }
        $sec = & $script:page 'technical/security.md'
        $sec | Should -Match 'Contributor on the engine job'
        $sec | Should -Match 'AcrPull'
    }

    It 'the two logging settings that hold a key are named, and nothing signs in with a key' {
        foreach ($rel in 'technical/security.md', 'reference/permissions.md') {
            $text = & $script:page $rel
            $text | Should -Match 'Application Insights connection string|connection string of Application Insights' -Because $rel
            $text | Should -Match 'Log Analytics workspace' -Because $rel
            $text | Should -Not -Match '(?i)no secret, password or key is stored' -Because $rel
        }
    }

    It 'the install grants its first access on the whole subscription (infra/hooks/preprovision.ps1, FIRSTSCOPE-1)' {
        foreach ($rel in 'understand/roles.md', 'technical/security.md', 'reference/permissions.md') {
            & $script:page $rel | Should -Match 'install grants that role on the whole subscription|install gives that permission on the whole subscription' -Because $rel
        }
        & $script:page 'understand/roles.md' | Should -Not -Match '(?i)starts with no permission'
        (Get-Content (Join-Path $script:repoRoot 'infra' 'hooks' 'preprovision.ps1') -Raw) | Should -Match "\`$default = 'migrate'"
    }

    It 'the remove command lists the safety copies and continues (infra/hooks/predown.ps1)' {
        & $script:page 'understand/safety-copies.md' | Should -Not -Match '(?i)refuses to run while safety copies'
    }

    It 'no page says how the product is developed (DOCS-SPLIT-1)' {
        foreach ($rel in 'technical/run-store.md', 'technical/architecture.md') {
            & $script:page $rel | Should -Not -Match 'schema-migrations\.md|repository.s .?schemas.? folder' -Because $rel
        }
        # halt.flag, the claims, deletions.jsonl, the log parts and the report have no schema.
        & $script:page 'technical/run-store.md' | Should -Not -Match '(?i)every document has a schema'
    }

    It 'a wave has no limit of machines: 60 is the most at once (WAVE-SIZE-REMOVE-1, plan-entry throttle)' {
        & $script:page 'reference/limits.md' | Should -Not -Match '1 to 60 per wave'
    }

    It 'no page has a lab number for the time of a move or the memory of the engine' {
        & $script:page 'technical/scale.md' | Should -Not -Match '(?i)about 20 minutes|190 MB|540 MB'
        & $script:page 'reference/limits.md' | Should -Not -Match '(?i)about 20 minutes'
        & $script:page 'technical/the-perimeter.md' | Should -Not -Match '(?i)eight minutes|14 minutes'
    }
}
