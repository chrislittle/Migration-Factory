#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# PLAN-WRITE-RACE-1: the last writer won on the plan.
#
# Every plan writer checked the version it read (PLANVER-2) and THEN wrote with
# an ordinary write, so two writers inside that gap both passed and the second
# overwrote the first - a decision could vanish from the plan with no word.
# Write-VmfTextDocumentIfVersion makes the check and the write one step: an
# If-Match on blob storage, a lock file on the file backend.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_WaveGate.ps1')
}

Describe 'PLAN-WRITE-RACE-1: the write checks the version in the same step' {
    BeforeEach {
        $script:dir = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pwr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:dir | Out-Null
        $script:file = Join-Path $script:dir 'plan.json'
        [System.IO.File]::WriteAllText($script:file, '{"a":1}', [System.Text.UTF8Encoding]::new($false))
        $script:v1 = InModuleScope VmMigrationFactory -Parameters @{ f = $script:file } { Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path $f) }
    }
    AfterEach { Remove-Item -LiteralPath $script:dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'writes when the document still holds the version read' {
        InModuleScope VmMigrationFactory -Parameters @{ f = $script:file; v = $script:v1 } {
            Write-VmfTextDocumentIfVersion -Path $f -Content '{"a":2}' -ExpectedVersion $v
        }
        Get-Content $script:file -Raw | Should -Be '{"a":2}'
        Test-Path "$script:file.lock" | Should -BeFalse -Because 'the lock goes when the write is done'
    }

    It 'refuses with 409 when somebody wrote it in between, and leaves their text' {
        [System.IO.File]::WriteAllText($script:file, '{"a":"theirs"}', [System.Text.UTF8Encoding]::new($false))
        { InModuleScope VmMigrationFactory -Parameters @{ f = $script:file; v = $script:v1 } {
                Write-VmfTextDocumentIfVersion -Path $f -Content '{"a":"mine"}' -ExpectedVersion $v } } |
            Should -Throw '409: Somebody changed the plan at the same time*'
        Get-Content $script:file -Raw | Should -Be '{"a":"theirs"}'
        Test-Path "$script:file.lock" | Should -BeFalse -Because 'the lock goes after a refusal too'
    }

    It 'a document that is gone is a change too' {
        Remove-Item -LiteralPath $script:file
        { InModuleScope VmMigrationFactory -Parameters @{ f = $script:file; v = $script:v1 } {
                Write-VmfTextDocumentIfVersion -Path $f -Content '{}' -ExpectedVersion $v } } | Should -Throw '409*'
        Test-Path $script:file | Should -BeFalse
    }

    It 'waits for another writer that holds the lock, then refuses rather than write under it' {
        New-Item -ItemType File -Path "$script:file.lock" | Out-Null
        { InModuleScope VmMigrationFactory -Parameters @{ f = $script:file; v = $script:v1 } {
                Write-VmfTextDocumentIfVersion -Path $f -Content '{"a":2}' -ExpectedVersion $v -WaitMilliseconds 200 } } |
            Should -Throw '409: The product is saving another change to the plan*'
        Get-Content $script:file -Raw | Should -Be '{"a":1}'
        Test-Path "$script:file.lock" | Should -BeTrue -Because 'it is the other writer''s lock, not ours to remove'
    }

    It 'a lock left by a writer that died (older than a minute) is removed' {
        $lock = New-Item -ItemType File -Path "$script:file.lock"
        $lock.LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-5)
        InModuleScope VmMigrationFactory -Parameters @{ f = $script:file; v = $script:v1 } {
            Write-VmfTextDocumentIfVersion -Path $f -Content '{"a":2}' -ExpectedVersion $v -WaitMilliseconds 200
        }
        Get-Content $script:file -Raw | Should -Be '{"a":2}'
    }

    It 'a stale lock that cannot be taken over still ends in an answer, not a loop' {
        # Found by the mutation run: a takeover that failed went round for ever.
        $lock = New-Item -ItemType File -Path "$script:file.lock"
        $lock.LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-5)
        $held = [System.IO.File]::Open("$script:file.lock", [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            { InModuleScope VmMigrationFactory -Parameters @{ f = $script:file; v = $script:v1 } {
                    Write-VmfTextDocumentIfVersion -Path $f -Content '{"a":2}' -ExpectedVersion $v -WaitMilliseconds 300 } } |
                Should -Throw '409: The product is saving another change to the plan*'
            $sw.Elapsed.TotalSeconds | Should -BeLessThan 5
        }
        finally { $held.Dispose() }
    }

    It 'a lock that is not ours is never removed by our write' {
        # While we hold the lock, another writer takes it over (it judged ours
        # stale). Our write finishes; only a lock holding our own token is ours
        # to remove, so theirs stays.
        $script:lockFile = "$script:file.lock"
        Mock -ModuleName VmMigrationFactory Get-VmfDocumentVersion {
            Set-Content -LiteralPath $script:lockFile -Value 'another-writer' -NoNewline
            $script:v1
        }
        InModuleScope VmMigrationFactory -Parameters @{ f = $script:file; v = $script:v1 } {
            Write-VmfTextDocumentIfVersion -Path $f -Content '{"a":2}' -ExpectedVersion $v
        }
        Get-Content $script:file -Raw | Should -Be '{"a":2}'
        Get-Content -LiteralPath $script:lockFile -Raw | Should -Be 'another-writer'
    }

    It 'a folder that is gone is a change, said at once - not ten seconds of waiting' {
        $gone = Join-Path $script:dir 'missing' 'plan.json'
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        { InModuleScope VmMigrationFactory -Parameters @{ f = $gone; v = $script:v1 } {
                Write-VmfTextDocumentIfVersion -Path $f -Content '{}' -ExpectedVersion $v } } | Should -Throw '409: Somebody changed the plan*'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 3
    }

    Context 'on blob storage' {
        BeforeEach {
            $script:blob = 'azblob://acct/cont/run-1/plan.json'
            $script:puts = [System.Collections.Generic.List[object]]::new()
            $script:stored = '{"a":1}'
            $script:afterPut = $null
            $script:getCode = 200
            $script:etag = '"0x8D1"'
            $script:putCode = 201
            Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
                if ($Method -eq 'GET') {
                    $text = if ($script:puts.Count -and $null -ne $script:afterPut) { $script:afterPut } else { $script:stored }
                    $h = @{}; if ($script:etag) { $h.ETag = @($script:etag) }
                    return [pscustomobject]@{ StatusCode = $script:getCode; Content = $text; Headers = $h }
                }
                $script:puts.Add([pscustomobject]@{ Uri = $Uri; Headers = $Headers; Body = $Body })
                [pscustomobject]@{ StatusCode = $script:putCode; Content = '' }
            }
        }

        It 'a PUT sent again after its answer was lost meets our own text: a success, not a 409' {
            # Invoke-VmfStorageRequest retries a PUT on a lost answer; the first
            # one landed, so the retry's If-Match fails with 412.
            $script:putCode = 412
            $script:afterPut = '{"a":2}'
            { InModuleScope VmMigrationFactory -Parameters @{ f = $script:blob; v = $script:v1 } {
                    Write-VmfTextDocumentIfVersion -Path $f -Content '{"a":2}' -ExpectedVersion $v } } | Should -Not -Throw
        }

        It 'a document that is gone is a change' {
            $script:getCode = 404
            { InModuleScope VmMigrationFactory -Parameters @{ f = $script:blob; v = $script:v1 } {
                    Write-VmfTextDocumentIfVersion -Path $f -Content '{}' -ExpectedVersion $v } } | Should -Throw '409*'
            $script:puts.Count | Should -Be 0
        }

        It 'a read with no ETag is refused - it cannot be written safely' {
            $script:etag = ''
            { InModuleScope VmMigrationFactory -Parameters @{ f = $script:blob; v = $script:v1 } {
                    Write-VmfTextDocumentIfVersion -Path $f -Content '{}' -ExpectedVersion $v } } | Should -Throw '*no ETag*'
            $script:puts.Count | Should -Be 0
        }

        It 'the write carries If-Match with the ETag of the text it checked' {
            InModuleScope VmMigrationFactory -Parameters @{ f = $script:blob; v = $script:v1 } {
                Write-VmfTextDocumentIfVersion -Path $f -Content '{"a":2}' -ExpectedVersion $v
            }
            $script:puts.Count | Should -Be 1
            $script:puts[0].Headers['If-Match'] | Should -Be '"0x8D1"'
            $script:puts[0].Body | Should -Be '{"a":2}'
            $script:puts[0].Uri | Should -Match 'acct\.blob\.core\.windows\.net/cont/run-1/plan\.json$'
        }

        It 'a version that differs is refused before any write' {
            $script:stored = '{"a":"theirs"}'
            { InModuleScope VmMigrationFactory -Parameters @{ f = $script:blob; v = $script:v1 } {
                    Write-VmfTextDocumentIfVersion -Path $f -Content '{"a":2}' -ExpectedVersion $v } } | Should -Throw '409*'
            $script:puts.Count | Should -Be 0
        }

        It 'a write by anybody between the check and the write fails the If-Match, and says 409' {
            $script:putCode = 412
            { InModuleScope VmMigrationFactory -Parameters @{ f = $script:blob; v = $script:v1 } {
                    Write-VmfTextDocumentIfVersion -Path $f -Content '{"a":2}' -ExpectedVersion $v } } | Should -Throw '409: Somebody changed the plan*'
        }
    }
}

Describe 'PLAN-WRITE-RACE-1: every plan writer uses it' {

    It '<Writer> writes the plan only through the conditional write' -ForEach @(
        @{ Writer = 'Set-VmfWavePlan' }, @{ Writer = 'Set-VmfMachineTarget' }, @{ Writer = 'Resolve-VmfDecision' }) {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' "$Writer.ps1")
        $code | Should -Match 'Write-VmfTextDocumentIfVersion'
        $code | Should -Not -Match "Write-VmfStore(Json|Text) -RunPath \`$RunPath -RelPath 'plan\.json'"
        $code | Should -Not -Match 'Write-VmfJsonDocument -Path \$PlanPath'
    }

    It 'the service says 409 for it on <Route>, so the page says the plan changed' -ForEach @(
        @{ Route = 'PostResolve' }, @{ Route = 'PostSetWaves' }, @{ Route = 'PostSetMachineTarget' }) {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' $Route 'run.ps1')
        $code | Should -Match "'\^409'\) \{ \[HttpStatusCode\]::Conflict \}"
    }

    Context 'a decision and another writer at once' {
        BeforeEach {
            $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pwr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vmId } {
                Initialize-VmfRun -RunPath $rp -RunId 'pwr' | Out-Null
                New-VmfStateDoc -RunPath $rp -RunId 'pwr' -VmId $vm -Wave 'w1' | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'NEEDS_DECISION' -Outcome ok -Detail 'files on the temporary disk' | Out-Null
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document @{ schemaVersion = 1; assessmentRunId = 'pwr'
                    entries = @(@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vm; wave = 'w1'; path = 'A'; assessment = @{ os = 'Linux' }
                            target = @{ size = 'Standard_D2s_v6' }; policy = @{ onDDataFound = 'stop' } }) }
            }
            $script:plan = Join-Path $script:rp 'plan.json'
            # RETRY-GATE-1: a decision is refused while its wave cannot start.
            Open-VmfTestWaveGate -RunPath $script:rp -PlanPath $script:plan
        }
        AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

        It 'the decision is refused, not lost, when the plan is written between its read and its write' {
            # The other writer lands while the decision is reading what the wave's
            # acceptance is bound to - after its read, before its write.
            Mock -ModuleName VmMigrationFactory Get-VmfDecisionSnapshot {
                $p = Get-Content $script:plan -Raw | ConvertFrom-Json -Depth 20
                $p | Add-Member -NotePropertyName waveOrder -NotePropertyValue @('w1') -Force
                [System.IO.File]::WriteAllText($script:plan, ($p | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
                @{}
            }
            { Resolve-VmfDecision -RunPath $script:rp -PlanPath $script:plan -VmId $script:vmId -PolicyOverride @{ onDDataFound = 'proceed' } `
                    -Note 'moved the files' -ResolvedBy 'operator@example.com' } | Should -Throw '409: Somebody changed the plan*'
            $now = Get-Content $script:plan -Raw | ConvertFrom-Json -Depth 20
            @($now.waveOrder) | Should -Be @('w1') -Because 'the other writer''s change stands'
            @($now.entries)[0].policy.onDDataFound | Should -Be 'stop'
            (InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vmId } { Read-VmfStateDoc -RunPath $rp -VmId $vm }).state |
                Should -Be 'NEEDS_DECISION' -Because 'a refused decision leaves the machine where it was'
        }

        It 'the wave editor''s save is refused, not written over, when the plan is written between its read and its write' {
            # The other writer (a decision) lands while the save checks which
            # machines have started - after its read, before its write.
            $script:once = $false
            Mock -ModuleName VmMigrationFactory Read-VmfStateDoc {
                if (-not $script:once) {
                    $script:once = $true
                    $p = Get-Content $script:plan -Raw | ConvertFrom-Json -Depth 20
                    @($p.entries)[0].policy.onDDataFound = 'proceed'
                    [System.IO.File]::WriteAllText($script:plan, ($p | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
                }
                $null
            }
            { Set-VmfWavePlan -RunPath $script:rp -PlanPath $script:plan -ChangedBy 'operator@example.com' -Confirm:$false `
                    -Layout @{ waves = @(@{ name = 'w2'; vmIds = @($script:vmId) }) } } | Should -Throw '409: Somebody changed the plan*'
            $now = Get-Content $script:plan -Raw | ConvertFrom-Json -Depth 20
            @($now.entries)[0].policy.onDDataFound | Should -Be 'proceed' -Because 'the decision is not lost'
            @($now.entries)[0].wave | Should -Be 'w1'
        }

        It 'a save built on a page read before a decision is refused: the page quotes the version it read' {
            # The review's case: the page sends every wave's settings on every
            # save, so its old value would be written over the decision - and a
            # check against the save's OWN read cannot see that.
            $pageRead = InModuleScope VmMigrationFactory -Parameters @{ f = $script:plan } { Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path $f) }
            $p = Get-Content $script:plan -Raw | ConvertFrom-Json -Depth 20
            @($p.entries)[0].policy.onDDataFound = 'proceed'
            [System.IO.File]::WriteAllText($script:plan, ($p | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
            { Set-VmfWavePlan -RunPath $script:rp -PlanPath $script:plan -ChangedBy 'operator@example.com' -Confirm:$false -ExpectedPlanVersion $pageRead `
                    -Layout @{ waves = @(@{ name = 'w1'; vmIds = @($script:vmId); onDDataFound = 'stop' }) } } | Should -Throw '409: The plan changed after this page read it*'
            @((Get-Content $script:plan -Raw | ConvertFrom-Json -Depth 20).entries)[0].policy.onDDataFound | Should -Be 'proceed'
            # The version as it is now is accepted.
            $now = InModuleScope VmMigrationFactory -Parameters @{ f = $script:plan } { Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path $f) }
            { Set-VmfWavePlan -RunPath $script:rp -PlanPath $script:plan -ChangedBy 'operator@example.com' -Confirm:$false -ExpectedPlanVersion $now `
                    -Layout @{ waves = @(@{ name = 'w1'; vmIds = @($script:vmId); onDDataFound = 'stop' }) } } | Should -Not -Throw
        }

        It 'a save refused at its write removes no quota check, and the log says no removal happened' {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
                Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/c1.json' -Document @{ wave = 'w1'; state = 'QUOTA_VERIFIED' }
            }
            $script:once = $false
            Mock -ModuleName VmMigrationFactory Read-VmfStateDoc {
                if (-not $script:once) {
                    $script:once = $true
                    $p = Get-Content $script:plan -Raw | ConvertFrom-Json -Depth 20
                    $p | Add-Member -NotePropertyName waveOrder -NotePropertyValue @('w1') -Force
                    [System.IO.File]::WriteAllText($script:plan, ($p | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
                }
                $null
            }
            { Set-VmfWavePlan -RunPath $script:rp -PlanPath $script:plan -ChangedBy 'operator@example.com' -Confirm:$false `
                    -Layout @{ waves = @(@{ name = 'w2'; vmIds = @($script:vmId) }) } } | Should -Throw '409*'
            Test-Path (Join-Path $script:rp 'capacity' 'c1.json') | Should -BeTrue
            $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Read-VmfEvents -RunPath $rp -Step 'capacity' }
            @($events | Where-Object { $_.detail -match 'was removed' }).Count | Should -Be 0
        }

        It 'a reservation made while the save writes is kept, and the log says to release it' {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
                Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/c1.json' -Document @{ wave = 'w1'; state = 'QUOTA_VERIFIED' }
            }
            $script:claimFile = Join-Path $script:rp 'capacity' 'c1.json'
            Mock -ModuleName VmMigrationFactory Write-VmfTextDocumentIfVersion {
                [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
                # A reserve job turns the quota check into a reservation now.
                [System.IO.File]::WriteAllText($script:claimFile, '{"wave":"w1","state":"RESERVED"}', [System.Text.UTF8Encoding]::new($false))
            }
            Set-VmfWavePlan -RunPath $script:rp -PlanPath $script:plan -ChangedBy 'operator@example.com' -Confirm:$false `
                -Layout @{ waves = @(@{ name = 'w1'; vmIds = @($script:vmId); onDDataFound = 'proceed' }) } | Out-Null
            (Get-Content $script:claimFile -Raw | ConvertFrom-Json).state | Should -Be 'RESERVED' -Because 'a record that bills is never removed'
            $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Read-VmfEvents -RunPath $rp -Step 'capacity' }
            @($events | Where-Object { $_.detail -match 'got a capacity reservation while its machines changed' }).Count | Should -Be 1
        }

        It 'a decision moves the plan sign-off onto the plan IT wrote, never onto another writer''s' {
            # The review's case: the carry-forward read the plan again after the
            # write, so a writer landing in between had the sign-off moved onto
            # an edit nobody approved.
            $signed = InModuleScope VmMigrationFactory -Parameters @{ f = $script:plan } { Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path $f) }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; h = $signed } {
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan-approval.json' -Document @{ schemaVersion = 3; planHash = $h; approvedBy = @{ identity = 'approver@example.com' } }
            }
            # MIGRATIONS-PAGE-OLD-READERS-1: a sign-off is v3, which moves only with
            # the wave approval - an approver accepting the decision the machine waits for.
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vmId } {
                Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'NEEDS_DECISION' -Outcome ok -ReasonCode 'dataOnTempDrive' -Detail 'files on the temporary disk' | Out-Null
            }
            $script:decided = $null
            # DECIDE-CARRY-RACE-1: the plan's write only; the carry writes its records
            # with the same helper, and they go to the real one.
            Mock -ModuleName VmMigrationFactory Write-VmfTextDocumentIfVersion -ParameterFilter { $Path -like '*plan.json' } {
                [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
                $script:decided = $Content
                # Another writer lands straight after. WAVE-APPROVE-1: it changes
                # the wave's machine - this added a waveOrder, which no longer
                # changes the wave an approval signs.
                $p = $Content | ConvertFrom-Json -Depth 20
                @($p.entries)[0].target.size = 'Standard_D4s_v6'
                [System.IO.File]::WriteAllText($Path, ($p | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
            }
            # RETRY-GATE-1: the other writer's change voids the sign-off, so the
            # wave cannot start and the machine is not re-armed - said, not
            # left waiting. The sign-off still names the decision's own text.
            { Resolve-VmfDecision -RunPath $script:rp -PlanPath $script:plan -VmId $script:vmId -PolicyOverride @{ onDDataFound = 'proceed' } `
                -Note 'moved the files' -ResolvedBy 'approver@example.com' -ResolvedRoles @('Vmf.Approver') } | Should -Throw '400: The change (onDDataFound=proceed) is saved*'
            $expected = InModuleScope VmMigrationFactory -Parameters @{ t = $script:decided } { Get-VmfDocumentVersion -Text $t }
            (Get-Content (Join-Path $script:rp 'plan-approval.json') -Raw | ConvertFrom-Json).planHash | Should -Be $expected
            # WAVE-APPROVE-1: and the wave's approval was carried onto the
            # decision's own text - then removed, because the other writer's
            # change is in its wave and nobody approved that.
            Test-Path (Join-Path $script:rp 'approvals' 'w1.json') | Should -BeFalse
        }

        It 'WAVE-APPROVE-1: the wave approval is carried onto the plan the decision wrote, never onto another writer''s' {
            $script:decided = $null
            Mock -ModuleName VmMigrationFactory Write-VmfTextDocumentIfVersion -ParameterFilter { $Path -like '*plan.json' } {
                [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
                $script:decided = $Content
                $p = $Content | ConvertFrom-Json -Depth 20
                @($p.entries)[0].target.size = 'Standard_D4s_v6'
                [System.IO.File]::WriteAllText($Path, ($p | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
            }
            Mock -ModuleName VmMigrationFactory Remove-VmfStaleWaveApprovals { @() }
            # An approver accepting the decision the machine waits for - the
            # one case a decision carries the wave approval.
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vmId } {
                Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'NEEDS_DECISION' -Outcome ok -ReasonCode 'dataOnTempDrive' -Detail 'files on the temporary disk' | Out-Null
            }
            { Resolve-VmfDecision -RunPath $script:rp -PlanPath $script:plan -VmId $script:vmId -PolicyOverride @{ onDDataFound = 'proceed' } `
                -Note 'moved the files' -ResolvedBy 'approver@example.com' -ResolvedRoles @('Vmf.Approver') } | Should -Throw '400: The change (onDDataFound=proceed) is saved*'
            $expected = InModuleScope VmMigrationFactory -Parameters @{ t = $script:decided } { Get-VmfWaveVersion -PlanText $t -Wave 'w1' }
            (Get-Content (Join-Path $script:rp 'approvals' 'w1.json') -Raw | ConvertFrom-Json).waveVersion | Should -BeExactly $expected
        }
    }
}
