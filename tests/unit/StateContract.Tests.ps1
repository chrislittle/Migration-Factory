#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STATE-3: the state document must satisfy its own contract.
#
# vm-state.schema.json is CLOSED (additionalProperties: false) and the engine was
# writing two shapes it had never heard of: the top-level `restore` record, and
# `safety.pristineSnapshotId`. Every restored machine's document was therefore
# invalid against the contract - the document that records the safety net was the
# one that failed validation.
#
# Nothing caught it because the only contract test asserted that REQUIRED fields
# were PRESENT. A closed schema's whole job is rejecting what it does not know,
# and that half was never exercised. So these tests VALIDATE - with Test-Json,
# which enforces additionalProperties and ships with PowerShell 7, so CI needs
# nothing extra.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'

    function Script:Test-DocAgainstSchema {
        param([Parameter(Mandatory)]$Document)
        $json = $Document | ConvertTo-Json -Depth 30
        try { Test-Json -Json $json -SchemaFile $script:schemaFile -ErrorAction Stop }
        catch { throw "state doc is INVALID against vm-state.schema.json: $($_.Exception.Message)" }
    }

    function Script:NewDocRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
            Initialize-VmfRun -RunPath $rp -RunId 'sc-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'sc-test' -VmId '/subscriptions/s/vm/a' -Wave 'w1' | Out-Null
        }
        $rp
    }
}

Describe 'STATE-3: the contract is actually enforced' {
    It 'the validator rejects an undeclared field - or these tests prove nothing' {
        # Guard the guard. If Test-Json ignored additionalProperties, every test
        # below would pass vacuously, which is exactly how the old contract test
        # missed this.
        $bad = '{"schemaVersion":2,"runId":"r","vmId":"v","state":"PLANNED","history":[],"somethingNobodyDeclared":1}'
        { Test-Json -Json $bad -SchemaFile $script:schemaFile -ErrorAction Stop } | Should -Throw
    }

    It 'and rejects an undeclared field inside a closed SUB-object' {
        # safety.pristineSnapshotId was exactly this case: the sub-object is
        # closed too, and nothing was checking it.
        $bad = '{"schemaVersion":2,"runId":"r","vmId":"v","state":"PLANNED","history":[],"safety":{"snapshotId":null,"madeUpField":"x"}}'
        { Test-Json -Json $bad -SchemaFile $script:schemaFile -ErrorAction Stop } | Should -Throw
    }
}

Describe 'STATE-3: documents the engine really writes' {
    It 'a fresh state doc validates' {
        $rp = Script:NewDocRun
        try {
            $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                Read-VmfStateDoc -RunPath $rp -VmId '/subscriptions/s/vm/a'
            }
            Script:Test-DocAgainstSchema -Document $doc | Should -BeTrue
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a doc carrying BOTH safety copies validates - the SAFETY-2 shape' {
        $rp = Script:NewDocRun
        try {
            $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                $d = Read-VmfStateDoc -RunPath $rp -VmId '/subscriptions/s/vm/a'
                $d | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                    snapshotId = '/snap/prepared'; cloneVmId = $null; pristineSnapshotId = '/snap/pristine' }) -Force
                Write-VmfStateDoc -RunPath $rp -Document $d
                Read-VmfStateDoc -RunPath $rp -VmId '/subscriptions/s/vm/a'
            }
            $doc.safety.pristineSnapshotId | Should -Be '/snap/pristine'
            Script:Test-DocAgainstSchema -Document $doc | Should -BeTrue
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'a doc carrying a put-back record validates - the shape that was invalid' {
        # Every field here is one Restore-VmfVm actually writes.
        $rp = Script:NewDocRun
        try {
            $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                $d = Read-VmfStateDoc -RunPath $rp -VmId '/subscriptions/s/vm/a'
                $d | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject][ordered]@{
                    restoredUtc = '2026-08-27T12:00:00.0000000Z'; restoredBy = 'operator'; note = $null
                    fromSnapshotId = '/snap/pristine'; fromCopy = 'pristine'
                    sizeAfter = 'Standard_D2s_v4'; diskNaming = 'new'
                    previousDiskId = '/disks/old'; previousDiskName = 'old'
                    newDiskId = '/disks/new'; newDiskName = 'new'
                    diskIdChanged = $true; retainedDiskId = '/disks/old'
                }) -Force
                Write-VmfStateDoc -RunPath $rp -Document $d
                Read-VmfStateDoc -RunPath $rp -VmId '/subscriptions/s/vm/a'
            }
            Script:Test-DocAgainstSchema -Document $doc | Should -BeTrue
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'every field Restore-VmfVm writes is declared in the schema' {
        # Validating one hand-built document proves that document. This reads the
        # field names out of the SOURCE, so a field added to the record without a
        # schema entry fails here even if no test happens to exercise it.
        $src = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Restore-VmfVm.ps1') -Raw
        # SWAP-REFUSED-AFTER-STOP-1: the record is built in one scriptblock,
        # $restoreRecord, used after the stopped window and in its catch.
        $block = [regex]::Match($src, '(?s)\$restoreRecord = \{.*?\[ordered\]@\{(.*?)\n        \}').Groups[1].Value
        $written = @([regex]::Matches($block, '(?m)^\s{12}([A-Za-z][A-Za-z0-9]*)\s*=') | ForEach-Object { $_.Groups[1].Value })
        @($written).Count | Should -BeGreaterThan 8 -Because 'the record block should have been found'

        $schema = Get-Content $script:schemaFile -Raw | ConvertFrom-Json
        $declared = @($schema.properties.restore.properties.PSObject.Properties.Name)
        $undeclared = @($written | Where-Object { $_ -notin $declared })
        $undeclared -join ', ' | Should -BeNullOrEmpty -Because 'a closed schema rejects the whole document over one unknown field'
    }

    It 'a doc in the middle of a rollback validates - the PREP-ROLLBACK-1 checkpoint and the disks it made (v19)' {
        $rp = Script:NewDocRun
        try {
            $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                $ctx = @{ RunPath = $rp; VmId = '/subscriptions/s/vm/a' }
                Set-VmfRollbackPending -Context $ctx -Kind 'disks' -State 'GUEST_PREP' -ReasonCode 'guestPrepBlocked' -Detail 'x' -Change 'mayHaveChanged'
                Add-VmfRollbackDiskDuringRollbackRecord -Context $ctx -DiskId '/disks/os-asitwas' -DiskName 'os-asitwas' -Lun $null
                Add-VmfRollbackDiskDuringRollbackRecord -Context $ctx -DiskId '/disks/d0-asitwas' -DiskName 'd0-asitwas' -Lun 0
                Set-VmfRollbackRecord -Context $ctx -Path 'disks' -OsDisk ([ordered]@{ id = '/disks/os-asitwas'; name = 'os-asitwas' }) -Done
                Read-VmfStateDoc -RunPath $rp -VmId '/subscriptions/s/vm/a'
            }
            $doc.rollbackPending.done | Should -BeTrue
            @($doc.rollbackDisksDuringRollback).Count | Should -Be 2
            Script:Test-DocAgainstSchema -Document $doc | Should -BeTrue
            $full = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                Set-VmfRollbackPending -Context @{ RunPath = $rp; VmId = '/subscriptions/s/vm/a' } -Kind 'full' -State 'STARTING' -ReasonCode 'bootFailedAfterConversion' -Detail 'x' -EvidenceRef 'bootdiag-a.json'
                Read-VmfStateDoc -RunPath $rp -VmId '/subscriptions/s/vm/a'
            }
            Script:Test-DocAgainstSchema -Document $full | Should -BeTrue
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'the shipped sample validates too' {
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw
        Test-Json -Json $sample -SchemaFile $script:schemaFile | Should -BeTrue
    }
}

Describe 'STATE-3: the version the store reads' {
    It 'the store writes exactly the version the schema declares' {
        # Asserted as an INVARIANT rather than a number. These two tests
        # hardcoded 2 and failed the moment UX-STUCK-1 added `recovery` and
        # bumped to 3 - a test failing because the version changed teaches
        # nothing, while a test failing because the WRITER and the CONTRACT
        # disagree is the bug that matters: documents written to a version the
        # schema does not describe.
        $declared = (Get-Content $script:schemaFile -Raw | ConvertFrom-Json).properties.schemaVersion.const
        $declared | Should -BeGreaterThan 1

        $rp = Script:NewDocRun
        try {
            $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                Read-VmfStateDoc -RunPath $rp -VmId '/subscriptions/s/vm/a'
            }
            $doc.schemaVersion | Should -Be $declared
            Script:Test-DocAgainstSchema -Document $doc | Should -BeTrue
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'OLD-STATE-READERS-FINISH-1: an earlier version is refused, never read - nothing of this version writes one' {
        foreach ($oldVersion in 1, ((Get-Content $script:schemaFile -Raw | ConvertFrom-Json).properties.schemaVersion.const - 1)) {
        $rp = Script:NewDocRun
        try {
            {
                InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; oldVersion = $oldVersion } {
                    $file = Get-ChildItem (Join-Path $rp 'state') -Filter '*.json' | Select-Object -First 1
                    $raw = Get-Content $file.FullName -Raw | ConvertFrom-Json
                    $raw.schemaVersion = $oldVersion
                    $raw | ConvertTo-Json -Depth 30 | Set-Content $file.FullName
                    Read-VmfStateDoc -RunPath $rp -VmId '/subscriptions/s/vm/a'
                }
            } | Should -Throw -ExpectedMessage "*unsupported schemaVersion '$oldVersion'*"
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    It 'but an unknown version is still refused, never silently misread' {
        $rp = Script:NewDocRun
        try {
            {
                InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                    $file = Get-ChildItem (Join-Path $rp 'state') -Filter '*.json' | Select-Object -First 1
                    $raw = Get-Content $file.FullName -Raw | ConvertFrom-Json
                    $raw.schemaVersion = 99
                    $raw | ConvertTo-Json -Depth 30 | Set-Content $file.FullName
                    Read-VmfStateDoc -RunPath $rp -VmId '/subscriptions/s/vm/a'
                }
            } | Should -Throw -ExpectedMessage '*unsupported schemaVersion*'
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'the rule is written down where the next person will look' {
        $store = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'StateStore.ps1') -Raw
        $store | Should -Match 'OLD-STATE-READERS-FINISH-1: the current version only'
    }
}

Describe 'STATE-3 sweep: the PLAN contract had the same hole' {
    # Validating real artifacts from safety-drill-4 against their own schemas
    # found run-status and capacity-claim clean, and the plan entry INVALID at
    # /policy/requireApproval. The policy object is closed and had never been
    # told about three policies the engine writes on every plan: safetyCopy
    # (SAFETY-2), requireApproval (approvals), onDriverBelowFloor (DRIVER-1).
    # This is the contract Stage 3 will freeze behind an API, so it matters more
    # than the state doc did.
    BeforeAll {
        $script:planSchema = Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json'
        $script:planner = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'Planner.ps1') -Raw
        $script:moduleSrc = @(
            Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Filter *.ps1 -Recurse |
                ForEach-Object { Get-Content $_.FullName -Raw }
        ) -join "`n"
    }

    It 'every policy the wave default writes is declared in the contract' {
        # Derived from the default set itself (WAVE-2 replaced the four-way
        # ring table with one), so adding a policy without a schema entry
        # still fails here - the guard that once caught three undeclared keys.
        $declared = @((Get-Content $script:planSchema -Raw | ConvertFrom-Json).properties.policy.properties.PSObject.Properties.Name)
        $block = [regex]::Match($script:planner, "(?s)function Get-VmfDefaultWavePolicy.*?\`$policy = @\{(.*?)\}").Groups[1].Value
        $written = @([regex]::Matches($block, '(?m)^\s*([A-Za-z][A-Za-z0-9]*)\s*=') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
        @($written).Count | Should -BeGreaterThan 3 -Because 'the default policy set should have been found'
        $undeclared = @($written | Where-Object { $_ -notin $declared })
        $undeclared -join ', ' | Should -BeNullOrEmpty -Because 'the policy object is closed, so one unknown key invalidates the whole plan'
    }

    It 'and every policy the engine READS is declared too' {
        # A policy nobody writes but the engine reads still has to be nameable
        # by a customer editing a plan, or it is unreachable.
        $declared = @((Get-Content $script:planSchema -Raw | ConvertFrom-Json).properties.policy.properties.PSObject.Properties.Name)
        $read = @([regex]::Matches($script:moduleSrc, "Get-VmfPolicy[^\r\n]*-Name\s+'([A-Za-z][A-Za-z0-9]*)'") |
            ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
        # MANUAL-REVIEW-1: bootableClone, read and never written, is gone.
        @($read).Count | Should -BeGreaterThan 2
        $undeclared = @($read | Where-Object { $_ -notin $declared })
        $undeclared -join ', ' | Should -BeNullOrEmpty
    }

    It 'a plan entry carrying every policy lever validates' {
        # Built from the shipped sample so it is the REAL entry shape, with only
        # the policy replaced - a hand-rolled fixture just tests the fixture.
        $entry = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json') -Raw | ConvertFrom-Json
        # FAIL-1 removed bootFailure and validationFailure: a failed machine
        # always goes back, so there was nothing left for them to choose.
        $entry.policy = [pscustomobject][ordered]@{
            safetyCopy = 'pristine'; onDDataFound = 'stop'
            keepSnapshotDays = 14; capacityGate = 'Reserved'
            requireApproval = $true
            acceleratedNetworking = 'ensureOn'; onDriverBelowFloor = 'stop'
        }
        Test-Json -Json ($entry | ConvertTo-Json -Depth 20) -SchemaFile $script:planSchema | Should -BeTrue
    }

    It 'the shipped plan sample validates' {
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json') -Raw
        Test-Json -Json $sample -SchemaFile $script:planSchema | Should -BeTrue
    }

    It 'the plan writer and the plan contract agree on the version' {
        # Asserted as an INVARIANT, not a number - the same lesson as the state
        # doc. This hardcoded 2 and failed the moment IAC-2 removed a policy and
        # bumped to 3, which teaches nothing; a writer disagreeing with its
        # contract is the bug that matters.
        #
        # EVAL-L3 went one better: the writer no longer spells the number at
        # all, it reads Get-VmfPlanSchemaVersion - the same declaration the
        # version gate reads. So compare the two things that must agree, and
        # require the writer to have stopped keeping its own copy.
        $declared = (Get-Content $script:planSchema -Raw | ConvertFrom-Json).properties.schemaVersion.const
        $declared | Should -BeGreaterThan 1
        InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion } | Should -Be $declared
        $np = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfPlan.ps1') -Raw
        $np | Should -Match 'schemaVersion = Get-VmfPlanSchemaVersion'
        # Not "no digits anywhere" - the plan DOCUMENT has a version of its
        # own, legitimately a different number on the same page. What must not
        # exist is a second copy of the ENTRY version.
        $np | Should -Not -Match "schemaVersion = $declared\b" `
            -Because 'a second copy of the entry version is how the writer and its gate drift apart'
    }
}
