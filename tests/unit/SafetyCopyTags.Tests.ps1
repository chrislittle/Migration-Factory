#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# FIND-COPY-1 - a safety copy has to say what it is, on itself.
#
# A safety copy is a snapshot in the resource group of the machine it came
# from, never in this product's. Removing the product leaves every one of them,
# and takes away both things that knew about them: the run store, which holds
# each machine's retention, and the daily pass that acts on it.
#
# What marked a copy before this was thin. The lock's NAME says vmf-safety-copy,
# which is real, but it is on the lock - remove the lock and the snapshot is
# anonymous. The resource NAME carries the run id, until a machine name over 75
# characters pushes it off the end. Tags sit on the resource, survive both, and
# are what `az resource list --tag` searches.
#
# THREE QUESTIONS WERE RAISED, AND ALL THREE ARE HERE:
#   * RBAC. The role holds Microsoft.Compute/snapshots/write and no tag action.
#     Tags in the CREATE call are covered by that; tagging an existing resource
#     is a different action and a different permission, so this must never do
#     one.
#   * A customer policy that denies tags. It must cost the LABEL, never the
#     COPY - this snapshot is the way back for a machine about to be changed.
#   * A policy that strips tags and reports success (POLICY-REVERT-1). Then the
#     find command is a lie, and somebody has to be told.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:azureOps = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1') -Raw
    $script:stateMachine = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
    $script:rbac = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json

    function Script:Tags {
        param($KeepDays = 7, $RunPath = 'azblob://vmfstateabc123/vmf-runs/run-9')
        & (Get-Module VmMigrationFactory) {
            param($k, $r)
            Get-VmfSafetyCopyTags -VmName 'app01' -RunId 'wave-3-20260910' -RunPath $r -KeepDays $k `
                -TakenUtc ([datetime]::Parse('2026-09-10T12:00:00Z'))
        } $KeepDays $RunPath
    }
}

Describe 'FIND-COPY-1: the tags say what a person needs to know' {

    It 'marks the copy so ONE literal command finds every one in a subscription' {
        # 'true', not the install's name. The manual prints that command with
        # nothing to substitute, and it stays right for somebody who installed
        # twice.
        (Script:Tags)['vmfSafetyCopy'] | Should -Be 'true'
    }

    It 'and names the machine and the run it belongs to' {
        $t = Script:Tags
        $t['vmfMachine'] | Should -Be 'app01'
        $t['vmfRun'] | Should -Be 'wave-3-20260910'
    }

    It 'and which install took it, for a subscription holding two' {
        (Script:Tags)['vmfStore'] | Should -Be 'vmfstateabc123'
    }

    It 'but never invents one when the run path does not carry it' {
        # A local run path has no account. An absent tag beats a made-up one.
        $t = Script:Tags -RunPath 'C:\runs\run-9'
        $t.ContainsKey('vmfStore') | Should -BeFalse
        $t['vmfSafetyCopy'] | Should -Be 'true' -Because 'the marker does not depend on the store'
    }

    It 'carries the days its wave accepted' {
        (Script:Tags -KeepDays 14)['vmfKeepDays'] | Should -Be '14'
    }

    It 'and UNKNOWN retention is left off, not turned into a number' {
        # Get-VmfRetentionDays returns $null when a wave's setting is unusable,
        # and the retention pass reads that as "leave this copy alone". A tag
        # saying 7 would contradict the code that decides.
        $t = Script:Tags -KeepDays $null
        $t.ContainsKey('vmfKeepDays') | Should -BeFalse
    }

    It 'and there is NO expiry date, because the clock has not started' {
        # The retention clock starts when the machine reaches MIGRATED. The
        # copy is taken BEFORE that, so a date computed here is wrong by
        # however long the migration takes - and a wrong date on a restore
        # point is worse than no date.
        $t = Script:Tags
        @($t.Keys) | Should -Not -Contain 'vmfExpiresUtc'
        $t['vmfTakenUtc'] | Should -Match '^2026-09-10T12:00:00'
    }
}

Describe 'FIND-COPY-1: a tag never costs a safety copy' {

    It 'the tags go in the CREATE call, which the role already permits' {
        # THE RBAC ANSWER, pinned. Tags supplied when a resource is created are
        # covered by that resource's own write action. Tagging an EXISTING
        # resource needs Microsoft.Resources/tags/write, which this role does
        # not hold and must not need - so nothing here may follow up with a tag
        # update.
        $write = @($script:rbac.PSObject.Properties.Value | ForEach-Object { $_ } |
            Where-Object { $_.cmdlet -eq 'New-AzSnapshot' })
        @($write).Count | Should -BeGreaterThan 0 -Because 'the snapshot write must be in the permission map'
        $script:rbac | Out-String | Should -Not -Match 'Microsoft\.Resources/tags/write'
        $script:azureOps | Should -Match '\$config\.Tags = \$tagTable'
        # no separate tag call anywhere in the module's Azure boundary
        $script:azureOps | Should -Not -Match 'Update-AzTag|New-AzTag|Set-AzResource .*-Tag'
    }

    It 'a refused tag is retried WITHOUT tags, so the copy is still taken' {
        # A customer policy can allow only certain tags, so the product must be
        # able to skip a tag it cannot write. The direction of
        # the risk is what makes it serious - this snapshot is the way back for
        # a machine that is about to be changed, so a label must never turn
        # into a failed migration.
        $fn = [regex]::Match($script:azureOps, '(?s)function New-VmfOsDiskSnapshot \{.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty
        $fn | Should -Match 'catch \{'
        $fn | Should -Match '\$config\.Tags = \$null'
        $fn | Should -Match 'if \(-not \$snap\) \{ \$snap = New-AzSnapshot'
    }

    It 'and a failure that is NOT about tags still throws' {
        # The retry must not swallow a real failure - a missing disk, a quota
        # refusal. It fails again without tags and throws from there, one
        # attempt later.
        $fn = [regex]::Match($script:azureOps, '(?s)function New-VmfOsDiskSnapshot \{.*?\n\}').Value
        $fn | Should -Not -Match 'catch \{ \}'
        $fn | Should -Not -Match '-ErrorAction SilentlyContinue\s*$'
        # the second attempt is NOT wrapped, so its exception reaches the caller
        $second = [regex]::Match($fn, 'if \(-not \$snap\) \{ \$snap = New-AzSnapshot[^\r\n]*').Value
        $second | Should -Not -Match 'try|catch'
    }

    It 'and the person is told the copy will not answer the find command' {
        # A silent fallback would leave the manual promising a query that
        # returns nothing for that copy.
        $script:azureOps | Should -Match "(?s)Write-Warning.*?taken without them.*?az resource list --tag vmfSafetyCopy=true"
    }
}

Describe 'FIND-COPY-1: what Azure kept is read back, not assumed' {

    It 'the tags that landed are checked against what was asked for' {
        # POLICY-REVERT-1, the hazard already in the brief: a policy with the
        # modify effect strips a property and reports success, exactly as one
        # does to a storage account's public network access. Here the copy
        # would be fine and the FIND COMMAND would be a lie - answering "none"
        # for a subscription full of them.
        $script:azureOps | Should -Match '\$landed = ConvertTo-VmfTagTable -Tags \$snap\.Tags'
        $script:azureOps | Should -Match 'if \(-not \$landed\.ContainsKey\(''vmfSafetyCopy''\)\)'
        $script:azureOps | Should -Match '(?s)did not keep its tags.*?a policy in'
    }

    It 'and it reads AZURE answer, not the object it was sent' {
        # $config is what we asked for; $snap is what Azure returned. Checking
        # the first proves nothing at all.
        $check = [regex]::Match($script:azureOps, '\$landed = ConvertTo-VmfTagTable -Tags \$(\w+)\.Tags').Groups[1].Value
        $check | Should -Be 'snap'
    }
}

Describe 'FIND-COPY-1: both copies of a machine are tagged' {

    It 'the pristine copy and the clean copy both carry them' {
        # Sequence C takes two per machine. One tagged and one not would make
        # the find command right and incomplete, which is worse than wrong.
        @([regex]::Matches($script:stateMachine, 'Get-VmfSafetyCopyTags -VmName')).Count |
            Should -Be 2 -Because 'the pristine copy and the clean copy'
        @([regex]::Matches($script:stateMachine, 'New-VmfOsDiskSnapshot[^\r\n]*\r?\n[^\r\n]*-Tags \$copyTags')).Count |
            Should -Be 2
    }

    It 'and each reads the retention from its OWN machine plan entry' {
        # Two waves in one run may have accepted different answers - the same
        # rule the retention pass follows.
        @([regex]::Matches($script:stateMachine, 'Get-VmfRetentionDays -PlanEntry \$Context\.Plan')).Count |
            Should -Be 2
    }
}

Describe 'FIND-COPY-1: the copy survives a subscription that refuses the tags' {
    # THE BEHAVIOUR, EXERCISED - not the shape of the source.
    #
    # The first version of this file checked that a catch block and a retry
    # line were PRESENT. A mutation that put `throw` at the top of that catch
    # passed all of it: the words were still there, and the copy was still
    # lost. A rule this important has to be run, not read.

    It 'takes the copy without tags when Azure refuses them' {
        InModuleScope VmMigrationFactory {
            $script:attempts = [System.Collections.Generic.List[object]]::new()
            Mock Get-AzSnapshot { $null }
            Mock New-AzSnapshotConfig { [pscustomobject]@{ Tags = $null } }
            Mock New-AzSnapshot {
                $script:attempts.Add($Snapshot.Tags)
                # A policy that denies the tag names refuses the whole create.
                if ($Snapshot.Tags -and $Snapshot.Tags.Count -gt 0) { throw 'RequestDisallowedByPolicy: tag name not permitted' }
                [pscustomobject]@{ Id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/snap-1'; Tags = @{} }
            }

            $id = New-VmfOsDiskSnapshot -ResourceGroupName 'rg' -SnapshotName 'snap-1' `
                -OsDiskId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/d1' `
                -Location 'centralus' -Tags @{ vmfSafetyCopy = 'true'; vmfMachine = 'app01' } `
                -WarningAction SilentlyContinue

            # THE COPY EXISTS. That is the whole point.
            $id | Should -Be '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/snap-1'
            $script:attempts.Count | Should -Be 2 -Because 'it tries with tags, then without'
            $script:attempts[0].Count | Should -BeGreaterThan 0
            # NOT @(...).Count -eq 0: @($null).Count is 1 in PowerShell, which
            # is how this assertion was wrong the first time.
            $script:attempts[1] | Should -BeNullOrEmpty -Because 'the second attempt carries no tags'
        }
    }

    It 'and a failure that is not about tags still reaches the caller' {
        InModuleScope VmMigrationFactory {
            Mock Get-AzSnapshot { $null }
            Mock New-AzSnapshotConfig { [pscustomobject]@{ Tags = $null } }
            Mock New-AzSnapshot { throw 'SourceDiskNotFound' }
            { New-VmfOsDiskSnapshot -ResourceGroupName 'rg' -SnapshotName 'snap-1' `
                -OsDiskId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/d1' `
                -Location 'centralus' -Tags @{ vmfSafetyCopy = 'true' } -WarningAction SilentlyContinue } |
                Should -Throw '*SourceDiskNotFound*'
        }
    }

    It 'and an untagged copy is never silently accepted as tagged' {
        # POLICY-REVERT-1 exercised: Azure accepts the create and returns a
        # resource with the tags stripped. The copy is fine; the find command
        # would answer "none" for it, and somebody has to be told.
        InModuleScope VmMigrationFactory {
            Mock Get-AzSnapshot { $null }
            Mock New-AzSnapshotConfig { [pscustomobject]@{ Tags = $null } }
            Mock New-AzSnapshot {
                [pscustomobject]@{ Id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/snapshots/snap-1'; Tags = @{} }
            }
            $warnings = @()
            $null = New-VmfOsDiskSnapshot -ResourceGroupName 'rg' -SnapshotName 'snap-1' `
                -OsDiskId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/d1' `
                -Location 'centralus' -Tags @{ vmfSafetyCopy = 'true' } -WarningVariable warnings -WarningAction SilentlyContinue
            ($warnings -join ' ') | Should -Match 'did not keep its tags'
        }
    }
}
